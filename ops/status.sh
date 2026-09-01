#!/usr/bin/env bash
# One screen that answers "is everything fine?" — containers, ports, TLS
# expiry, disk, memory. Read-only; safe to run at any time.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

step "containers"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    --filter 'name=vpsplus-' | sed 's/^/  /'

step "endpoints"
for key in "${APP_KEYS[@]}"; do
    domain="$(app_var "$key" DOMAIN)"
    port="$(app_var "$key" PORT)"
    [[ -n "$domain" ]] || continue

    local_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" || echo '---')"
    # --max-time is short on purpose: this should be a glance, not a wait.
    pub_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${domain}/" || echo '---')"

    line="$(printf '  %-8s :%-5s local %-4s   https://%-28s %s' \
        "$key" "$port" "$local_code" "$domain" "$pub_code")"
    if [[ "$local_code" =~ ^[23] && "$pub_code" =~ ^[23] ]]; then
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    else
        printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
    fi
done

step "tls"
if [[ -d /etc/letsencrypt/live ]]; then
    for cert in /etc/letsencrypt/live/*/fullchain.pem; do
        [[ -e "$cert" ]] || continue
        name="$(basename "$(dirname "$cert")")"
        end="$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
        days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
        # Certbot renews at 30 days; anything under that means renewal is stuck.
        if   (( days < 15 )); then col="$C_RED"
        elif (( days < 30 )); then col="$C_YELLOW"
        else                       col="$C_GREEN"; fi
        printf '  %s%-34s %3d days left%s\n' "$col" "$name" "$days" "$C_RESET"
    done
else
    log "no certificates issued yet"
fi

step "postgres"
if docker exec vpsplus-postgres pg_isready -U "${POSTGRES_USER:-vpsplus}" >/dev/null 2>&1; then
    ok "accepting connections"
    docker exec vpsplus-postgres psql -U "${POSTGRES_USER:-vpsplus}" -d postgres -tA -c \
        "SELECT '  ' || datname || '  ' || pg_size_pretty(pg_database_size(datname))
         FROM pg_database WHERE datistemplate = false ORDER BY datname;"
else
    warn "not reachable"
fi

step "host"
printf '  uptime  %s\n' "$(uptime -p 2>/dev/null || uptime)"
free -h  | awk 'NR==1{printf "  mem     %-8s used %-8s free %s\n","total","",""} NR==2{printf "  mem     %-8s %-8s %s\n",$2,$3,$4}'
df -h /  | awk 'NR==2{printf "  disk    %s used of %s (%s)\n",$3,$2,$5}'
docker system df --format '  docker  {{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null | head -3

step "agents"
for cli in claude gemini codex hermes; do
    if command -v "$cli" >/dev/null 2>&1; then
        printf '  %-8s %s\n' "$cli" "$("$cli" --version 2>/dev/null | head -1 | cut -c1-60)"
    else
        printf '  %-8s %snot installed%s\n' "$cli" "$C_DIM" "$C_RESET"
    fi
done
