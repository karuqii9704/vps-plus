#!/usr/bin/env bash
# Redeploy one app, or all of them.
#
#   ops/deploy.sh plus            pull, rebuild, restart
#   ops/deploy.sh plus --no-pull  rebuild the current checkout
#   ops/deploy.sh all
#
# Trilux is a special case: its site is bind-mounted, so a content change needs
# only a pull and a restart, and the script says so rather than rebuilding an
# image that has not changed.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

STACK="$ROOT/stack"
ENV_FILE="$STACK/stack.env"
PULL=1
declare -a TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull) PULL=0; shift ;;
        all)       TARGETS=("${APP_KEYS[@]}"); shift ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         TARGETS+=("$1"); shift ;;
    esac
done

[[ ${#TARGETS[@]} -gt 0 ]] || die "which app? one of: ${APP_KEYS[*]}  (or 'all')"

compose() {
    docker compose --env-file "$ENV_FILE" -f "$STACK/docker-compose.yml" \
        --profile "$1" "${@:2}"
}

for key in "${TARGETS[@]}"; do
    dir="$REPOS_DIR/$(app_dir_name "$key")"
    [[ -d "$dir/.git" ]] || { warn "$key: no checkout at $dir — skipped"; continue; }

    step "$key"

    if [[ $PULL -eq 1 ]]; then
        before="$(git -C "$dir" rev-parse --short HEAD)"
        git -C "$dir" fetch --prune origin >/dev/null
        branch="$(app_var "$key" BRANCH)"
        if git -C "$dir" merge --ff-only "origin/${branch}" >/dev/null 2>&1; then
            after="$(git -C "$dir" rev-parse --short HEAD)"
            if [[ "$before" == "$after" ]]; then
                log "already at $after — nothing new upstream"
            else
                ok "$before -> $after"
                git -C "$dir" log --oneline "$before..$after" | head -10 | sed 's/^/      /'
            fi
        else
            # Refusing here is the point: a forced pull would silently discard
            # a hotfix someone edited straight on the server.
            warn "cannot fast-forward (dirty tree or local commits) — deploying the checkout as-is"
        fi
    fi

    if [[ "$key" == "trilux" ]]; then
        # The image holds only the Express host; the site comes from the mount.
        log "bind-mounted site — restarting without a rebuild"
        compose "$key" restart "$key"
    else
        # Build args must be re-exported: NEXT_PUBLIC_*/VITE_* are compiled in.
        while IFS='=' read -r k v; do export "$k=${v%\"}"; done \
            < <(grep -E '^(NEXT_PUBLIC_|VITE_)[A-Z0-9_]*=' "$STACK/apps/$key.env" 2>/dev/null || true)

        compose "$key" build "$key"
        compose "$key" up -d "$key"
    fi

    port="$(app_var "$key" PORT)"
    sleep 4
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}/" || echo '---')"
    if [[ "$code" =~ ^[23] ]]; then
        ok "$key is answering on :$port (HTTP $code)"
    else
        warn "$key returned HTTP $code — docker logs vpsplus-$key --tail 50"
    fi
done

# Old build layers add up fast on a small disk.
log "pruning dangling images"
docker image prune -f >/dev/null
