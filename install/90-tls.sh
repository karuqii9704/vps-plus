#!/usr/bin/env bash
# Let's Encrypt certificates, one run per app.
#
# This is the only stage that can fail for a reason outside the VPS: if the DNS
# A record does not resolve here yet, the HTTP-01 challenge cannot succeed. So
# each domain is resolved first and skipped with an explanation rather than
# burning a rate-limit attempt.
#
# Let's Encrypt allows 5 failed validations per account per hostname per hour.
# Re-running this stage after fixing DNS is safe; hammering it is not.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_TLS:-1}" "tls" && exit 0

: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL in vps.conf}"

if ! command -v certbot >/dev/null 2>&1; then
    info "installing certbot"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx
fi

MY_IP="$(curl -s --max-time 10 https://api.ipify.org || true)"
[[ -n "$MY_IP" ]] && log "this VPS is $MY_IP" || warn "could not determine the public IP; DNS checks will be skipped"

resolves_here() {
    local host="$1" got
    [[ -n "$MY_IP" ]] || return 0          # cannot check — let certbot decide
    got="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')"
    if [[ -z "$got" ]]; then warn "$host does not resolve at all"; return 1; fi
    if [[ "$got" == "$MY_IP" ]]; then return 0; fi
    warn "$host resolves to $got, not $MY_IP"
    return 1
}

issued=0 skipped=0
for key in "${APP_KEYS[@]}"; do
    domain="$(app_var "$key" DOMAIN)"
    alt="$(app_var "$key" ALT_DOMAIN)"
    [[ -n "$domain" ]] || continue

    if [[ -d "/etc/letsencrypt/live/$domain" ]]; then
        exp="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null | cut -d= -f2)"
        ok "$domain already has a certificate (expires $exp)"
        continue
    fi

    declare -a domains=(-d "$domain")
    if ! resolves_here "$domain"; then
        warn "$key: skipping — point the A record here, then: sudo $ROOT/bootstrap.sh --force 90"
        skipped=$((skipped+1))
        continue
    fi
    # The apex is added to the same certificate only when it also resolves
    # here; a stale apex record would otherwise fail the whole request.
    if [[ -n "$alt" ]] && resolves_here "$alt"; then
        domains+=(-d "$alt")
    fi

    info "requesting a certificate for $domain${alt:+ + $alt}"
    if certbot --nginx --non-interactive --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        --redirect --keep-until-expiring \
        "${domains[@]}"
    then
        ok "$domain secured"
        issued=$((issued+1))
    else
        warn "$key: certbot failed — see /var/log/letsencrypt/letsencrypt.log"
        skipped=$((skipped+1))
    fi
done

# --- renewal ----------------------------------------------------------------
# The certbot package installs a systemd timer. Verify it rather than assume,
# because a silent renewal failure surfaces as an expired cert 90 days later.
if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
    ok "renewal timer active: $(systemctl list-timers --all | awk '/certbot/{print $1, $2, $3}' | head -1)"
else
    warn "no certbot timer found; adding a daily cron entry"
    printf '%s\n' '0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"' \
        > /etc/cron.d/certbot-renew
fi

certbot renew --dry-run >/dev/null 2>&1 \
    && ok "renewal dry-run passed" \
    || warn "renewal dry-run failed — check it before the first expiry"

printf '\n'
log "issued: $issued   skipped: $skipped"
