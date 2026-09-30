#!/usr/bin/env bash
# Update the ecommerce app (Laravel 13 + Livewire, subdomain ecommerce.plusthe.site).
#
#   ops/deploy-ecommerce.sh              pull, rebuild deps if the lockfiles
#                                        changed, migrate, re-cache, restart
#   ops/deploy-ecommerce.sh --no-pull    skip the git pull (local edits only)
#
# Not part of ops/deploy.sh on purpose: that script is keyed on APP_KEYS
# (plus/studio/trilux/nalar) and rebuilds Docker images. This app is a bind
# mount + FPM container, so an update is a pull plus an in-container artisan
# run — no image rebuild (only the Dockerfile itself changes the image).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

DIR="$REPOS_DIR/ecommerce"
IMAGE="vpsplus-ecommerce:latest"
CONTAINER="vpsplus-ecommerce-fpm"
PULL=1
[[ "${1:-}" == "--no-pull" ]] && PULL=0

[[ -d "$DIR/.git" ]] || die "no checkout at $DIR"

artisan() {
    docker run --rm --network host --user 33:33 \
        -v "$DIR:$DIR" -w "$DIR" "$IMAGE" php artisan "$@"
}

# --- 1. code ----------------------------------------------------------------
COMPOSER_BEFORE="$(sha256sum "$DIR/composer.lock" | cut -d' ' -f1)"
NPM_BEFORE="$(sha256sum "$DIR/package-lock.json" | cut -d' ' -f1)"

if [[ $PULL -eq 1 ]]; then
    step "git pull"
    BRANCH="$(sudo -u plus git -C "$DIR" rev-parse --abbrev-ref HEAD)"
    # The production branch is NOT necessarily on `origin`. ecommerce runs on
    # polish/launch-ready, which exists only on the `mirror` remote; assuming
    # origin made every deploy print "not a fast-forward" and silently pull
    # nothing. Follow the branch's own upstream instead, and fall back to
    # origin/<branch> only when the branch tracks nothing.
    UPSTREAM="$(sudo -u plus git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [[ -n "$UPSTREAM" ]]; then
        REMOTE="${UPSTREAM%%/*}"
        REF="$UPSTREAM"
    else
        REMOTE=origin
        REF="origin/$BRANCH"
    fi
    sudo -u plus git -C "$DIR" fetch --prune "$REMOTE"
    if sudo -u plus git -C "$DIR" merge --ff-only "$REF"; then
        ok "ecommerce at $(sudo -u plus git -C "$DIR" rev-parse --short HEAD) ($REF)"
    else
        warn "pull not a fast-forward — left the working tree alone"
    fi
fi

# --- 2. dependencies --------------------------------------------------------
if [[ "$(sha256sum "$DIR/composer.lock" | cut -d' ' -f1)" != "$COMPOSER_BEFORE" || ! -f "$DIR/vendor/autoload.php" ]]; then
    step "composer install"
    docker run --rm --user "$(id -u plus):$(id -g plus)" -e HOME=/tmp \
        -v "$DIR:$DIR" -w "$DIR" "$IMAGE" \
        composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
fi

if [[ "$(sha256sum "$DIR/package-lock.json" | cut -d' ' -f1)" != "$NPM_BEFORE" || ! -d "$DIR/public/build" ]]; then
    step "vite build"
    docker run --rm --user "$(id -u plus):$(id -g plus)" -e HOME=/tmp \
        -v "$DIR:$DIR" -w "$DIR" node:22-alpine \
        sh -c "npm ci --no-audit --no-fund && npm run build"
fi

# --- 3. database + caches ---------------------------------------------------
step "migrate"
artisan migrate --force

step "re-cache"
artisan optimize

step "restart fpm"
docker restart "$CONTAINER" >/dev/null
sleep 3
docker ps --format '{{.Names}}: {{.Status}}' | grep ecommerce || true
