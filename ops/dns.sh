#!/usr/bin/env bash
# Point every domain in vps.conf at this VPS, through the Hostinger DNS API.
#
#   ops/dns.sh                  show what would change, touch nothing
#   ops/dns.sh --apply          make the changes
#   ops/dns.sh --ip 1.2.3.4     use a specific IP instead of autodetecting
#
# Dry run is the default on purpose: DNS is the one thing here that breaks a
# live site for everyone, not just for you, and it breaks for as long as the
# old TTL says.
#
# Needs a token from hPanel -> Account -> API. Scope it to DNS if you can:
#
#   export HOSTINGER_API_TOKEN=...
#
# Docs: https://developers.hostinger.com  (GET/PUT/DELETE /api/dns/v1/zones/{domain})

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

API="https://developers.hostinger.com/api/dns/v1/zones"
TTL="${DNS_TTL:-3600}"
APPLY=0
IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=1; shift ;;
        --ip)      IP="$2"; shift 2 ;;
        --ttl)     TTL="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown flag: $1" ;;
    esac
done

: "${HOSTINGER_API_TOKEN:?set HOSTINGER_API_TOKEN — hPanel > Account > API}"
need_cmd curl
need_cmd jq

# --- target ip --------------------------------------------------------------
if [[ -z "$IP" ]]; then
    IP="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
    [[ -n "$IP" ]] || die "could not detect this machine's public IP — pass --ip"
    log "detected public IP: $IP"
fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not an IPv4 address: $IP"

# Running this from your laptop would point every domain at your home router.
if [[ -f /var/lib/vps-plus/00-base ]]; then
    log "running on the provisioned VPS"
else
    warn "this does not look like the VPS (no /var/lib/vps-plus stamp)."
    warn "If \$IP is your laptop's address, every site will break. Check: $IP"
fi

api() { # api <method> <path> [body]
    local method="$1" path="$2" body="${3:-}"
    local args=(-fsS -X "$method" -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
                -H 'Content-Type: application/json' -H 'Accept: application/json')
    if [[ -n "$body" ]]; then args+=(-d "$body"); fi
    curl "${args[@]}" "$API/$path"
}

# --- zone discovery ---------------------------------------------------------
# "www.plusthe.site" lives in the "plusthe.site" zone, but a naive last-two-
# labels rule breaks on suffixes like .co.id. Ask the API instead: walk the
# name from the left, and the first suffix that returns a zone is the right one.
find_zone() {
    local fqdn="$1" candidate="$fqdn"
    while [[ "$candidate" == *.* ]]; do
        if api GET "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
        candidate="${candidate#*.}"
        [[ "$candidate" == *.* ]] || break
    done
    return 1
}

# --- plan -------------------------------------------------------------------
# Nothing is written in this pass. Every change is collected first so the whole
# plan can be shown before a single record moves.
declare -a PLAN_ZONE=() PLAN_NAME=() PLAN_ACTION=() PLAN_DETAIL=()

plan_domain() {
    local fqdn="$1" label="$2" zone name current_json existing_a existing_cname

    zone="$(find_zone "$fqdn")" || {
        warn "$label: no Hostinger zone found for $fqdn — is the domain on another account?"
        return 0
    }

    # The record name relative to the zone. The apex is "@" in Hostinger's API.
    if [[ "$fqdn" == "$zone" ]]; then name="@"; else name="${fqdn%".$zone"}"; fi

    current_json="$(api GET "$zone")"
    existing_a="$(jq -r --arg n "$name" \
        '[.[] | select(.name==$n and .type=="A") | .records[].content] | join(", ")' <<<"$current_json")"
    existing_cname="$(jq -r --arg n "$name" \
        '[.[] | select(.name==$n and .type=="CNAME") | .records[].content] | join(", ")' <<<"$current_json")"

    if [[ -n "$existing_cname" ]]; then
        # A name cannot hold both a CNAME and an A record. `overwrite` only
        # clears records matching BOTH name and type, so the CNAME survives an
        # A-record write and the zone ends up invalid. Delete it explicitly.
        PLAN_ZONE+=("$zone"); PLAN_NAME+=("$name")
        PLAN_ACTION+=("delete-cname")
        PLAN_DETAIL+=("$label  $fqdn  CNAME -> $existing_cname  (must go before an A record can exist)")
    fi

    if [[ "$existing_a" == "$IP" ]]; then
        PLAN_ZONE+=("$zone"); PLAN_NAME+=("$name")
        PLAN_ACTION+=("noop")
        PLAN_DETAIL+=("$label  $fqdn  already A -> $IP")
    else
        PLAN_ZONE+=("$zone"); PLAN_NAME+=("$name")
        PLAN_ACTION+=("set-a")
        PLAN_DETAIL+=("$label  $fqdn  A ${existing_a:-(none)} -> $IP")
    fi
}

step "planning"
for key in "${APP_KEYS[@]}"; do
    d="$(app_var "$key" DOMAIN)"; a="$(app_var "$key" ALT_DOMAIN)"
    if [[ -n "$d" ]]; then plan_domain "$d" "$key"; fi
    if [[ -n "$a" ]]; then plan_domain "$a" "$key(alt)"; fi
done

[[ ${#PLAN_ACTION[@]} -gt 0 ]] || { warn "no domains configured in vps.conf"; exit 0; }

printf '\n'
changes=0
for i in "${!PLAN_ACTION[@]}"; do
    case "${PLAN_ACTION[$i]}" in
        noop)         printf '  %s= %s%s\n' "$C_DIM"    "${PLAN_DETAIL[$i]}" "$C_RESET" ;;
        delete-cname) printf '  %s- %s%s\n' "$C_YELLOW" "${PLAN_DETAIL[$i]}" "$C_RESET"; changes=$((changes+1)) ;;
        set-a)        printf '  %s+ %s%s\n' "$C_GREEN"  "${PLAN_DETAIL[$i]}" "$C_RESET"; changes=$((changes+1)) ;;
    esac
done
printf '\n'

if [[ $changes -eq 0 ]]; then
    ok "DNS already points here — nothing to do"
    exit 0
fi

if [[ $APPLY -eq 0 ]]; then
    warn "$changes change(s) planned. This was a dry run; nothing was modified."
    warn "Re-run with --apply once the VPS actually serves the sites:"
    warn "  ops/status.sh          # local ports must answer first"
    warn "  ops/dns.sh --apply"
    exit 0
fi

# --- apply ------------------------------------------------------------------
step "applying"
for i in "${!PLAN_ACTION[@]}"; do
    zone="${PLAN_ZONE[$i]}"; name="${PLAN_NAME[$i]}"

    case "${PLAN_ACTION[$i]}" in
        noop) continue ;;

        delete-cname)
            body="$(jq -nc --arg n "$name" '{filters: [{name: $n, type: "CNAME"}]}')"
            api DELETE "$zone" "$body" >/dev/null
            ok "deleted CNAME $name.$zone"
            ;;

        set-a)
            body="$(jq -nc --arg n "$name" --arg ip "$IP" --argjson ttl "$TTL" \
                '{overwrite: true, zone: [{name: $n, type: "A", ttl: $ttl, records: [{content: $ip}]}]}')"

            # Validate first: a 422 here costs nothing, whereas a bad PUT is a
            # live zone with a broken record in it.
            if ! api POST "$zone/validate" "$body" >/dev/null 2>&1; then
                warn "validation failed for $name.$zone — skipped"
                continue
            fi
            api PUT "$zone" "$body" >/dev/null
            ok "set A $name.$zone -> $IP (ttl ${TTL}s)"
            ;;
    esac
done

printf '\n'
log "Propagation takes up to the previous record's TTL. Check with:"
for key in "${APP_KEYS[@]}"; do
    d="$(app_var "$key" DOMAIN)"
    if [[ -n "$d" ]]; then log "  dig +short $d"; fi
done
printf '\n'
warn "Once every name resolves here, issue the certificates:"
warn "  sudo $ROOT/bootstrap.sh --force 90"
