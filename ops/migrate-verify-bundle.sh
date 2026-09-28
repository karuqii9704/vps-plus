#!/usr/bin/env bash
# migrate-verify-bundle.sh — prove a migration bundle is restorable, on the box
# that produced it. No second VPS needed.
#
#   ops/migrate-verify-bundle.sh <bundle-dir> [--fresh]
#
# Unpacks every archive into a staging root and hashes the result against the
# live source. Anything that differs is reported and classified: files under a
# known live-write path are expected drift (agents and the gateway rewrite them
# continuously), everything else is a real finding.
#
#   --fresh   re-extract instead of reusing the staging root
#
# Never touches /.

set -uo pipefail
B="${1:?usage: migrate-verify-bundle.sh <bundle-dir> [--fresh]}"
FRESH=0; [[ "${2:-}" == "--fresh" ]] && FRESH=1
B="$(cd "$B" && pwd)"
STAGE=/tmp/restore-sim
STAMP="$STAGE/.bundle-fingerprint"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '%s ok%s %s\n'   "$GREEN"  "$OFF" "$*"; }
bad()  { printf '%sfail%s %s\n'  "$RED"    "$OFF" "$*"; }
note() { printf '%snb  %s %s\n'  "$YELLOW" "$OFF" "$*"; }
info() { printf '%s ::%s %s\n'   "$DIM"    "$OFF" "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$BOLD" "$OFF" "$BOLD" "$*" "$OFF"; }

[[ -d "$B/archives" ]] || { bad "not a bundle (no archives/): $B"; exit 1; }
[[ -d "$1" ]] || { bad "no such bundle: $1"; exit 1; }

# REPOS_DIR is not in vps.conf (it is a bootstrap default), and this script must
# run without sourcing lib/common.sh so it works from anywhere.
REPOS_DIR="${REPOS_DIR:-/srv/repos}"

# Paths rewritten continuously by running processes — a difference here is
# drift, not damage.
VOLATILE='^(home/[^/]+/\.claude|root/\.hermes|srv/hq/status|srv/plus-office/data/.*\.db|srv/notes/00-HQ/tasks\.md|.*/\.git/|.*/\.claude/|\.bundle-fingerprint)'
# Working trees of the app checkouts. These are NOT volatile by nature, but on
# this box autonomous agents (srv/hq/run-agent.sh) write to them continuously,
# so a difference here usually means uncommitted work rather than corruption.
# It gets its own bucket and its own warning: uncommitted work is exactly what
# gets lost in a migration.
WORKTREE='^srv/repos/'

FP="$(sha256sum < "$B/checksums.sha256" | cut -d' ' -f1)"

# --- 1. extract -------------------------------------------------------------
step "staging"
if (( ! FRESH )) && [[ -f "$STAMP" && "$(cat "$STAMP")" == "$FP" ]]; then
    info "staging root already matches this bundle — reusing (--fresh to re-extract)"
else
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    for a in "$B"/archives/*.tar.zst; do
        info "unpacking $(basename "$a")  ($(du -h "$a" | cut -f1))"
        tar --zstd -xf "$a" -C "$STAGE" || bad "extract failed: $a"
    done
    printf '%s' "$FP" > "$STAMP"
    ok "extracted $(ls -1 "$B"/archives/*.tar.zst | wc -l) archives"
fi

# --- 2. hash staged, then the same paths on the live source -----------------
step "hashing"
A=$(mktemp); LIST=$(mktemp); Bs=$(mktemp); DIFFS=$(mktemp)
trap 'rm -f "$A" "$LIST" "$Bs" "$DIFFS"' EXIT

( cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) \
    | sed 's#  \./#  #' | sort -k2 > "$A"
cut -d' ' -f3- "$A" > "$LIST"
TOTAL=$(wc -l < "$LIST")
ok "$TOTAL files in the bundle"

sed 's#^#/#' "$LIST" | xargs -d '\n' -r sha256sum 2>/dev/null \
    | sed 's#  /#  #' | sort -k2 > "$Bs"

diff "$A" "$Bs" | grep '^<' | sed 's#^< [a-f0-9]*  ##' > "$DIFFS" || true

# --- 3. classify ------------------------------------------------------------
step "fidelity"
NDIFF=$(wc -l < "$DIFFS")
n_vol=0; n_wt=0; n_real=0
if [[ $NDIFF -gt 0 ]]; then
    n_vol=$(grep -cE "$VOLATILE" "$DIFFS" || true)
    REST=$(grep -vE "$VOLATILE" "$DIFFS" || true)
    # Guard on emptiness: `printf '%s\n' "" | grep -vc pattern` counts 1 and
    # reported a phantom "1 differ outside every allowlist" on a clean run.
    if [[ -n "${REST//[$'\n']/}" ]]; then
        n_wt=$(printf '%s\n' "$REST" | grep -cE "$WORKTREE" || true)
        n_real=$(printf '%s\n' "$REST" | grep -vcE "$WORKTREE" || true)
    fi
fi
IDENTICAL=$(( TOTAL - NDIFF ))
ok "identical to source          : $IDENTICAL / $TOTAL"
if [[ $n_vol -gt 0 ]]; then
    note "$n_vol differ — known live-write paths (gateway, agent state, git metadata). Expected drift."
fi
if [[ $n_wt -gt 0 ]]; then
    note "$n_wt differ inside an app checkout — usually uncommitted agent work."
    printf '%s\n' "$REST" | grep -E "$WORKTREE" | sed 's/^/      /' | head -20
    for repo in $(printf '%s\n' "$REST" | grep -E "$WORKTREE" \
                  | sed 's#^srv/repos/\([^/]*\)/.*#\1#' | sort -u); do
        d="$REPOS_DIR/$repo"
        [[ -d "$d/.git" ]] || continue
        br=$(git -C "$d" branch --show-current 2>/dev/null)
        dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
        warn "$repo: branch '$br', $dirty uncommitted path(s) — PUSH BEFORE MIGRATING"
    done
fi
if [[ $n_real -gt 0 ]]; then
    bad "$n_real differ outside every allowlist:"
    printf '%s\n' "$REST" | grep -vE "$WORKTREE" | sed 's/^/      /' | head -25
else
    ok "no unexplained differences"
fi

# --- 4. critical files ------------------------------------------------------
step "critical files"
fail=0
need() {
    if [[ -e "$STAGE/$1" ]]; then ok "$2"
    else bad "MISSING: $2  ($1)"; fail=1; fi
}
need srv/vps-plus/vps.conf                                   "deploy config (gitignored)"
need srv/vps-plus/stack/stack.env                            "postgres/app secrets"
need srv/vps-plus/stack/apps/plus.env                        "plus app env"
need srv/vps-plus/stack/apps/studio.env                      "studio app env"
need srv/vps-plus/stack/apps/trilux.env                      "trilux app env"
need srv/vps-plus/apps/supabase/supabase.env                 "supabase secrets"
need srv/vps-plus/apps/supabase/roles.sql                    "supabase roles"
need srv/vps-plus/stack/ojs/docker-compose.yml               "OJS compose"
need srv/vps-plus/stack/ecommerce/Dockerfile                 "ecommerce image"
need srv/vps-plus/ops/migrate-import.sh                      "import script"
need home/plus/.ssh/id_ed25519                               "deploy SSH key"
need home/plus/bec-repo/ojs-3.5.0-5                          "OJS source repo"
need root/.hermes/.env                                       "gateway API keys"
need root/.hermes/config.yaml                                "gateway config"
need var/www/biadenrekacipta/ojs/config.inc.php              "OJS db credentials"
need var/www/biadenrekacipta/ojs-files/journals              "OJS submissions"
need etc/nginx/sites-enabled/plus-office.conf                "office vhost (outside APP_KEYS)"
need etc/nginx/sites-enabled/zz-ojs.conf                     "OJS vhost"
need etc/nginx/plus-office.htpasswd                          "office password file"
need etc/letsencrypt/live/www.plusthe.site/privkey.pem       "TLS key (www)"
need etc/letsencrypt/live/testojs.plusthe.site/privkey.pem   "TLS key (ojs)"
need etc/apparmor.d/local/usr.sbin.mysqld                    "AppArmor MySQL override"
need etc/systemd/system/mysql.service.d/override.conf        "MySQL datadir override"
need etc/systemd/system/ojs-queue.service                    "OJS queue unit"
need etc/docker/daemon.json                                  "docker daemon config"
need var/spool/cron/crontabs/root                            "root crontab"
need var/spool/cron/crontabs/plus                            "deploy crontab"

# --- 5. database dumps ------------------------------------------------------
# A dump is valid if psql can replay it — NOT if it contains tables. Two of the
# four app databases on this box are legitimately empty (created by the compose
# file, never given a schema), so a table count is informational only.
step "database dumps"
for f in "$B"/db/*.sql.gz; do
    n=$(basename "$f")
    # NOTE: never write `zcat | head -1 | grep -q` here — with `set -o pipefail`
    # zcat dies of SIGPIPE and the pipeline reports failure even on a match,
    # which made every valid dump look broken.
    if ! gzip -t "$f" 2>/dev/null; then
        bad "$n — corrupt gzip"; fail=1; continue
    fi
    marker=$(zcat "$f" 2>/dev/null | grep -m1 -E '^(--|CREATE |DROP |SET |\\restrict)' || true)
    if [[ -z "$marker" ]]; then
        bad "$n — decompresses but contains no SQL statements"; fail=1; continue
    fi
    t=$(zcat "$f" 2>/dev/null | grep -c '^CREATE TABLE' || true)
    if [[ "$t" -gt 0 ]]; then
        ok "$n — replayable, $t tables"
    else
        note "$n — replayable, 0 tables (database is genuinely empty — confirm that is intended)"
    fi
done

# --- 6. verdict -------------------------------------------------------------
printf '\n'
if [[ $fail -eq 0 && $n_real -eq 0 ]]; then
    ok "BUNDLE VERIFIED — restorable, no unexplained differences"
else
    bad "PROBLEMS FOUND — see above"
    exit 1
fi
printf '%s(staging: %s — %s; remove with rm -rf %s)%s\n' \
    "$DIM" "$STAGE" "$(du -sh "$STAGE" 2>/dev/null | cut -f1)" "$STAGE" "$OFF"
