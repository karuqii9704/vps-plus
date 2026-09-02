#!/usr/bin/env bash
# Runs ops/smoke.mjs against every site that has a domain in vps.conf.
#
#   ops/smoke.sh              test the public HTTPS URLs
#   ops/smoke.sh --local      test 127.0.0.1:<port> instead, bypassing DNS and
#                             nginx — use this before the DNS cutover
#
# First run downloads a headless Chromium (~150 MB) and its system libraries.
# That needs sudo once; after that the script needs nothing.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

LOCAL=0
if [[ "${1:-}" == "--local" ]]; then LOCAL=1; fi

need_cmd node "stage 20 installs it; log out and back in if it is missing"
need_cmd jq   "stage 00 installs it"

# --- playwright -------------------------------------------------------------
# Kept out of the repo as a dependency: this is the only thing here that wants
# a node_modules, and installing it on demand keeps the clone small.
PW_DIR="$ROOT/.playwright"
if [[ ! -d "$PW_DIR/node_modules/playwright" ]]; then
    info "installing playwright (first run only)"
    mkdir -p "$PW_DIR"
    ( cd "$PW_DIR" && npm init -y >/dev/null && npm install playwright@latest --no-audit --no-fund >/dev/null )
    ok "playwright installed"
fi

export NODE_PATH="$PW_DIR/node_modules"

if ! node -e "require('playwright').chromium.executablePath()" >/dev/null 2>&1; then
    info "downloading chromium + system libraries (needs sudo, once)"
    ( cd "$PW_DIR" && sudo npx playwright install --with-deps chromium ) \
        || die "chromium install failed — try: sudo npx playwright install-deps"
fi

# --- targets ----------------------------------------------------------------
# Built as JSON so the node script needs no shell parsing of its own.
targets="[]"
for key in "${APP_KEYS[@]}"; do
    domain="$(app_var "$key" DOMAIN)"
    port="$(app_var "$key" PORT)"
    [[ -n "$domain" ]] || continue

    if [[ $LOCAL -eq 1 ]]; then
        url="http://127.0.0.1:${port}"
    else
        url="https://${domain}"
    fi

    # Only these two serve a health endpoint; the Next.js apps do not.
    health=""
    case "$key" in
        studio|trilux) health="/api/health" ;;
        plus)          health="/api/health" ;;
    esac

    targets="$(jq -c --arg k "$key" --arg u "$url" --arg h "$health" \
        '. + [{key: $k, url: $u} + (if $h == "" then {} else {health: $h} end)]' <<<"$targets")"
done

[[ "$(jq length <<<"$targets")" -gt 0 ]] || { warn "no domains configured in vps.conf"; exit 0; }

if [[ $LOCAL -eq 1 ]]; then log "testing loopback ports (DNS and nginx bypassed)"; fi

SMOKE_TARGETS="$targets" exec node "$ROOT/ops/smoke.mjs"
