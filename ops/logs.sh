#!/usr/bin/env bash
# Tail one app's container logs, or nginx's.
#
#   ops/logs.sh plus            follow the last 100 lines
#   ops/logs.sh plus 500        follow the last 500
#   ops/logs.sh nginx           the access + error logs for every vhost
#   ops/logs.sh postgres

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

target="${1:-}"; lines="${2:-100}"
[[ -n "$target" ]] || die "usage: ops/logs.sh <${APP_KEYS[*]}|postgres|nginx> [lines]"

if [[ "$target" == nginx ]]; then
    exec tail -n "$lines" -f /var/log/nginx/*.log
fi

exec docker logs --tail "$lines" -f "vpsplus-${target}"
