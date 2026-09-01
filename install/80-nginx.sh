#!/usr/bin/env bash
# Nginx as the single public listener, one vhost per configured app.
#
# Nginx runs on the host rather than in a container. It is the only thing on
# port 443, certbot's --nginx plugin edits its config directly, and putting it
# in compose would mean re-solving both of those for no benefit.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_NGINX:-1}" "nginx" && exit 0

if ! command -v nginx >/dev/null 2>&1; then
    info "installing nginx"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi

install -d -m 755 /var/www/certbot

# --- shared http-level config ----------------------------------------------
# $connection_upgrade is used by every vhost for websocket passthrough; it can
# only be defined once, at http level.
cat > /etc/nginx/conf.d/00-vps-plus.conf <<'CONF'
# vps-plus shared settings. Managed by install/80-nginx.sh — edits are lost.

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Long hostnames plus certbot's own additions overflow the default bucket.
server_names_hash_bucket_size 128;

# Do not advertise the exact version to anyone probing the host.
server_tokens off;
CONF

# Ubuntu ships a default vhost that answers on port 80 for any unmatched host.
# Left in place it serves the nginx welcome page to anyone who points a domain
# at this IP.
rm -f /etc/nginx/sites-enabled/default

# --- per-app vhosts ---------------------------------------------------------
TEMPLATE="$ROOT/stack/nginx/site.conf.template"
[[ -f "$TEMPLATE" ]] || die "missing $TEMPLATE"

rendered=0
for key in "${APP_KEYS[@]}"; do
    domain="$(app_var "$key" DOMAIN)"
    port="$(app_var "$key" PORT)"
    [[ -n "$domain" ]] || { log "$key: no domain — no vhost"; continue; }

    # An apex that should 301 to www (only plus. has one today).
    alt="$(app_var "$key" ALT_DOMAIN)"
    alt_block=""
    if [[ -n "$alt" ]]; then
        alt_block=$(cat <<ALT
server {
    listen 80;
    listen [::]:80;
    server_name ${alt};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://${domain}\$request_uri;
    }
}
ALT
)
    fi

    out="/etc/nginx/sites-available/${key}.conf"
    sed -e "s|__DOMAIN__|${domain}|g" \
        -e "s|__PORT__|${port}|g" \
        -e "s|__APP__|${key}|g" \
        "$TEMPLATE" > "$out"

    # __ALT_SERVER__ can span many lines, so it is substituted with a file read
    # rather than a sed expression.
    if [[ -n "$alt_block" ]]; then
        printf '%s\n' "$alt_block" > "/tmp/alt-$key"
        sed -i -e "/__ALT_SERVER__/r /tmp/alt-$key" -e "/__ALT_SERVER__/d" "$out"
        rm -f "/tmp/alt-$key"
    else
        sed -i "/__ALT_SERVER__/d" "$out"
    fi

    ln -sfn "$out" "/etc/nginx/sites-enabled/${key}.conf"
    ok "$key -> ${domain}${alt:+ (+ ${alt} redirect)} -> 127.0.0.1:${port}"
    rendered=$((rendered+1))
done

[[ $rendered -gt 0 ]] || { warn "no domains configured; nginx left with no vhosts"; exit 0; }

# --- apply ------------------------------------------------------------------
if nginx -t 2>&1 | sed 's/^/    /'; then
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx
    ok "nginx reloaded with $rendered vhost(s)"
else
    die "nginx config test failed — nothing was reloaded, the old config is still live"
fi

printf '\n'
warn "DNS must point at this VPS before stage 90 can issue certificates:"
ip="$(curl -s --max-time 5 https://api.ipify.org || echo '<vps-ip>')"
for key in "${APP_KEYS[@]}"; do
    d="$(app_var "$key" DOMAIN)"; a="$(app_var "$key" ALT_DOMAIN)"
    if [[ -n "$d" ]]; then log "  A  $d  ->  $ip"; fi
    if [[ -n "$a" ]]; then log "  A  $a  ->  $ip"; fi
done
