#!/usr/bin/env bash
# Builds and starts the application containers.
#
# An app runs only if it has a domain in vps.conf and its checkout exists. That
# rule is deliberate: a half-configured app that starts anyway is worse than
# one that visibly did not, because nginx will then proxy to a container
# serving someone else's error page.
#
# Build args are lifted out of stack/apps/<app>.env, because NEXT_PUBLIC_* and
# VITE_* are compiled into the browser bundle and compose cannot read env_file
# at build time.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_APPS:-1}" "apps" && exit 0

need_cmd docker
STACK="$ROOT/stack"
ENV_FILE="$STACK/stack.env"
[[ -f "$ENV_FILE" ]] || die "stack/stack.env is missing — run stage 60 first"

# --- env files --------------------------------------------------------------
# compose fails hard on a missing env_file, so seed any that the bundle did not
# provide. A seeded file has empty values, which is exactly what makes the app
# fall back to its degraded mode rather than crash.
for a in plus studio trilux nalar; do
    if [[ ! -f "$STACK/apps/$a.env" ]]; then
        install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
            "$STACK/apps/$a.env.example" "$STACK/apps/$a.env"
        warn "created stack/apps/$a.env from the example — it has NO real keys yet"
    fi
done

# --- which apps -------------------------------------------------------------
declare -a ACTIVE=()
for key in "${APP_KEYS[@]}"; do
    domain="$(app_var "$key" DOMAIN)"
    dir="$REPOS_DIR/$(app_dir_name "$key")"

    if [[ -z "$domain" ]]; then
        log "$key: no DOMAIN_$(echo "$key" | tr a-z A-Z) set — not started"
        continue
    fi
    if [[ ! -d "$dir" ]]; then
        warn "$key: no checkout at $dir — not started (run stage 50)"
        continue
    fi
    ACTIVE+=("$key")
done

[[ ${#ACTIVE[@]} -gt 0 ]] || { warn "no apps are configured; nothing to build"; exit 0; }
info "building: ${ACTIVE[*]}"

# --- build args -------------------------------------------------------------
# Pull the public values out of each app env file and export them, so compose
# interpolates them into the `args:` blocks. Only these names are read; a typo
# in the env file becomes an empty build arg, not a leaked secret.
export_public() {
    local file="$1" prefix="$2" rename_prefix="${3:-}"
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r k v; do
        [[ "$k" == ${prefix}* ]] || continue
        v="${v%\"}"; v="${v#\"}"          # tolerate quoted values
        export "${rename_prefix}${k}=${v}"
    done < <(grep -E "^${prefix}[A-Z0-9_]*=" "$file" || true)
}

export_public "$STACK/apps/plus.env"   NEXT_PUBLIC_
export_public "$STACK/apps/studio.env" VITE_
# NALAR uses the same NEXT_PUBLIC_* names as plus., so they are namespaced in
# the compose file to stop one app's Supabase URL from being baked into the
# other's bundle.
export_public "$STACK/apps/nalar.env"  NEXT_PUBLIC_ NALAR_

# --- build + up -------------------------------------------------------------
declare -a PROFILE_ARGS=()
for key in "${ACTIVE[@]}"; do PROFILE_ARGS+=(--profile "$key"); done

compose() {
    docker compose --env-file "$ENV_FILE" -f "$STACK/docker-compose.yml" \
        "${PROFILE_ARGS[@]}" "$@"
}

# Built one at a time on purpose: a 2 GB VPS running four parallel `next build`
# jobs is the single most reliable way to get an OOM kill.
for key in "${ACTIVE[@]}"; do
    info "build: $key"
    compose build "$key" || die "build failed for $key — see the output above"
done

info "starting containers"
compose up -d "${ACTIVE[@]}"

# --- verify -----------------------------------------------------------------
# A container that is "up" can still be crash-looping. Give each one a moment,
# then check the port actually answers.
sleep 5
printf '\n'
for key in "${ACTIVE[@]}"; do
    port="$(app_var "$key" PORT)"
    name="vpsplus-$key"
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" || echo '---')"

    if [[ "$state" == running && "$code" =~ ^[23] ]]; then
        ok  "$key  $state  :$port  HTTP $code"
    else
        warn "$key  $state  :$port  HTTP $code   ->  docker logs $name"
    fi
done
