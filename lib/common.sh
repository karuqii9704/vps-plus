#!/usr/bin/env bash
# Shared helpers. Sourced by bootstrap.sh and every install/ module, so it must
# stay side-effect free: define things, touch nothing.

set -euo pipefail

# --- output -----------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=; C_DIM=; C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=
fi

log()   { printf '%s\n' "${C_DIM}  ${*}${C_RESET}"; }
info()  { printf '%s\n' "${C_BLUE}::${C_RESET} ${*}"; }
ok()    { printf '%s\n' "${C_GREEN} ok${C_RESET} ${*}"; }
warn()  { printf '%s\n' "${C_YELLOW}  !${C_RESET} ${*}" >&2; }
die()   { printf '%s\n' "${C_RED}fail${C_RESET} ${*}" >&2; exit 1; }

step()  { printf '\n%s\n' "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}${*}${C_RESET}"; }

# skip <flag-value> <name> -> returns 0 (and prints) when the stage is disabled
skip_unless() {
    local flag="${1:-0}" name="$2"
    if [[ "$flag" != "1" ]]; then
        printf '%s\n' "${C_DIM}--- skipped: ${name} (disabled in vps.conf)${C_RESET}"
        return 0
    fi
    return 1
}

# --- idempotence ------------------------------------------------------------
# Every module records completion so a re-run is cheap. Delete a stamp to force
# that stage to run again: rm /srv/vps-plus/.state/30-ai-clis
STATE_DIR="${STATE_DIR:-/var/lib/vps-plus}"

stamped()  { [[ -f "$STATE_DIR/$1" ]]; }
stamp()    { mkdir -p "$STATE_DIR"; date -Iseconds > "$STATE_DIR/$1"; }

# --- guards -----------------------------------------------------------------
need_root() { [[ $EUID -eq 0 ]] || die "this stage needs root; re-run bootstrap.sh with sudo"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1 ${2:+($2)}"
}

# as_deploy <cmd...> — run something as DEPLOY_USER with a login shell, so nvm
# and ~/.local/bin are on PATH. Used for anything that writes into their $HOME.
as_deploy() {
    local u="${DEPLOY_USER:?DEPLOY_USER not set}"
    if [[ "$(id -un)" == "$u" ]]; then
        bash -lc "$*"
    else
        runuser -u "$u" -- bash -lc "$*"
    fi
}

deploy_home() { getent passwd "${DEPLOY_USER:?}" | cut -d: -f6; }

# --- config -----------------------------------------------------------------
# Reads vps.conf next to the repo root. Fails loudly rather than running with
# half a configuration, because a blank DOMAIN silently produces a broken vhost.
load_conf() {
    local root="$1"
    [[ -f "$root/vps.conf" ]] || die "no vps.conf — copy vps.conf.example to vps.conf and edit it"
    # shellcheck disable=SC1090
    set -a; source "$root/vps.conf"; set +a
    : "${DEPLOY_USER:?DEPLOY_USER missing from vps.conf}"
    : "${SRV_ROOT:?SRV_ROOT missing from vps.conf}"
    : "${REPOS_DIR:?REPOS_DIR missing from vps.conf}"
}

# --- secrets ----------------------------------------------------------------
# gen_secret writes a random value into stack/stack.env only if the key has no
# value yet, so re-running bootstrap never rotates a live password.
upsert_env() {
    local file="$1" key="$2" value="$3"
    touch "$file"; chmod 600 "$file"
    if grep -qE "^${key}=" "$file"; then
        # Value may contain / and &, so use a python-free sed with a rare delim.
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

read_env() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    sed -nE "s/^${key}=(.*)$/\1/p" "$file" | tail -1
}

random_secret() { head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-32; }

# --- apps -------------------------------------------------------------------
# The single source of truth for what an app is called, where it lives and how
# it is reached. Everything else (compose, nginx, deploy.sh) derives from this.
#   key | repo dir | DOMAIN_ var | PORT_ var | REPO_ var | BRANCH_ var
APP_KEYS=(plus studio trilux nalar)

app_dir_name() {
    case "$1" in
        plus)   echo "plusthesite-" ;;
        studio) echo "studio-plusthesite" ;;
        trilux) echo "trilux-design-page" ;;
        nalar)  echo "new-nalar" ;;
        *)      die "unknown app key: $1" ;;
    esac
}

app_var() { # app_var <key> <PREFIX>  ->  value of ${PREFIX}_<KEY>
    local key="$1" prefix="$2" name
    name="${prefix}_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${!name-}"
}
