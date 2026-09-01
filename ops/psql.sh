#!/usr/bin/env bash
# A psql shell on one of the app databases, without hunting for the password.
#
#   ops/psql.sh nalar                     interactive
#   ops/psql.sh nalar < dump.sql          load a dump
#   ops/psql.sh nalar -c 'SELECT 1'       one-off query

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

db="${1:-postgres}"; shift || true

# -i keeps stdin open so redirection works; -t is added only for a real
# terminal, because `docker exec -t` mangles piped input.
tty_flag=()
if [[ -t 0 ]]; then tty_flag=(-t); fi

exec docker exec -i "${tty_flag[@]}" vpsplus-postgres \
    psql -U "${POSTGRES_USER:-vpsplus}" -d "$db" "$@"
