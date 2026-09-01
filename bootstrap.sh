#!/usr/bin/env bash
#
#  vps-plus — one command turns a bare Ubuntu VPS into the working environment
#  described in README.md: AI CLIs, four sites behind nginx+TLS, Postgres.
#
#      sudo ./bootstrap.sh              # everything enabled in vps.conf
#      sudo ./bootstrap.sh 30 70        # only those stages
#      sudo ./bootstrap.sh --list       # what would run
#      sudo ./bootstrap.sh --force 50   # ignore the completion stamp
#
#  Every stage is idempotent. Re-running after a failure resumes rather than
#  starting over: finished stages are stamped in /var/lib/vps-plus.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

FORCE=0
declare -a ONLY=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE=1; shift ;;
        --list|-l)  ls -1 "$ROOT/install" | sed 's/\.sh$//'; exit 0 ;;
        --help|-h)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         die "unknown flag: $1" ;;
        *)          ONLY+=("$1"); shift ;;
    esac
done

need_root
load_conf "$ROOT"

export ROOT FORCE
export STATE_DIR="/var/lib/vps-plus"
mkdir -p "$STATE_DIR"

# A full run touches apt, docker and certbot; a log is the difference between
# "it broke" and "it broke here".
LOG="/var/log/vps-plus-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

printf '%s\n' "${C_BOLD}vps-plus${C_RESET} — $(date -Is)"
log "config : $ROOT/vps.conf"
log "log    : $LOG"
log "user   : $DEPLOY_USER"

run_stage() {
    local file="$1" name stamp_name
    name="$(basename "$file" .sh)"
    stamp_name="$name"

    if [[ ${#ONLY[@]} -gt 0 ]]; then
        local match=0 want
        for want in "${ONLY[@]}"; do
            if [[ "$name" == "$want" || "$name" == "$want"-* ]]; then match=1; fi
        done
        [[ $match -eq 1 ]] || return 0
    fi

    if [[ $FORCE -eq 0 ]] && stamped "$stamp_name"; then
        printf '%s\n' "${C_DIM}--- done already: ${name}  (--force to redo)${C_RESET}"
        return 0
    fi

    step "$name"
    # Each module runs in its own shell: a `set -e` abort inside one module
    # stops the run, but a stray `cd` or variable cannot leak into the next.
    if bash "$file"; then
        stamp "$stamp_name"
    else
        die "stage $name failed — fix it, then re-run: sudo ./bootstrap.sh $name"
    fi
}

for f in "$ROOT"/install/*.sh; do
    run_stage "$f"
done

printf '\n%s\n' "${C_GREEN}${C_BOLD}done.${C_RESET}"
cat <<SUMMARY

  next steps
    ${SRV_ROOT}/ops/status.sh          what is running, and is it healthy
    ${SRV_ROOT}/ops/deploy.sh plus     pull + rebuild + restart one app
    ${SRV_ROOT}/ops/backup.sh          pg_dump + config snapshot

  log: $LOG
SUMMARY
