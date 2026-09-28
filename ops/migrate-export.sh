#!/usr/bin/env bash
# migrate-export.sh — build a self-contained, verifiable migration bundle.
#
#   ops/migrate-export.sh                       write to $DATA_DIR/migrate/bundle-<stamp>
#   ops/migrate-export.sh --dry-run             print the plan + real sizes, write nothing
#   ops/migrate-export.sh --verify <dir>        re-check an existing bundle's checksums
#   ops/migrate-export.sh --dest /path          write the bundle somewhere else
#
# What gets left OUT by default (all of it is rebuildable, and it is ~75% of the
# bytes on this box). Every one of these is opt-in via a flag:
#
#   --include-build         node_modules / .next / dist / vendor / framework caches
#   --include-old-backups   /srv/data/backups    (we take fresh dumps instead)
#   --keep-ojs-logs         OJS scheduledTaskLogs + usageStats (~366M of log)
#   --lean                  additionally skip .local, bec-bundle, .claude, .gemini
#   --skip-ojs-qa           do not package /srv/ojs-qa at all
#
# /srv/ojs-qa (the QA staging instance) is packaged as its OWN archive, never
# folded into srv.tar.zst, so the main restore stays lean. migrate-import.sh
# only unpacks it with --with-ojs-qa.
#
# What ALWAYS gets included, because losing it is unrecoverable:
#   * every Postgres database            (plusthesite carries the supabase
#                                         `auth` + `storage` schemas)
#   * the MySQL OJS database             (ojs_local — NOT in Postgres)
#   * /srv, /home/<deploy>, /root/.hermes, the OJS web tree + its uploads
#   * every .env / vps.conf / stack.env / SSH key / TLS cert
#   * AppArmor + systemd + docker + fail2ban + crontab hand-edits
#
# The bundle holds PLAINTEXT CREDENTIALS. Keep it mode 700, move it over SSH,
# and shred it on both ends when the migration is done.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

# --- options ----------------------------------------------------------------
MODE=export
DRY_RUN=0
FORCE=0
LEAN=0
INCLUDE_BUILD=0
SKIP_OJS_QA=0
INCLUDE_OLD_BACKUPS=0
KEEP_OJS_LOGS=0
MIGRATE_ROOT="${DATA_DIR}/migrate"
BUNDLE=""

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)             DRY_RUN=1; shift ;;
        --force)               FORCE=1; shift ;;
        --lean)                LEAN=1; shift ;;
        --include-build)       INCLUDE_BUILD=1; shift ;;
        --skip-ojs-qa)         SKIP_OJS_QA=1; shift ;;
        --include-old-backups) INCLUDE_OLD_BACKUPS=1; shift ;;
        --keep-ojs-logs)       KEEP_OJS_LOGS=1; shift ;;
        --dest)                MIGRATE_ROOT="${2:?--dest needs a path}"; shift 2 ;;
        --verify)              MODE=verify; BUNDLE="${2:-}"; shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

need_root

DEPLOY="$DEPLOY_USER"
DHOME="$(deploy_home)"
WWW_ROOT=/var/www/biadenrekacipta
OJS_DIR="$WWW_ROOT/ojs"
OJS_FILES="$WWW_ROOT/ojs-files"

# vps.conf's SRV_ROOT is the repo checkout itself (/srv/vps-plus), NOT the
# directory that holds it. The tree we actually pack is its parent.
REPO_ROOT="${SRV_ROOT%/}"
SRV="$(dirname "$REPO_ROOT")"

for d in "${REPOS_DIR%/}" "${DATA_DIR%/}"; do
    [[ "$d" == "$SRV/"* ]] || die "SRV_ROOT / REPOS_DIR / DATA_DIR do not share a parent:
    SRV_ROOT  = $REPO_ROOT
    REPOS_DIR = $REPOS_DIR
    DATA_DIR  = $DATA_DIR
This script packs \$(dirname SRV_ROOT) as a single archive and writes its
exclusions relative to /. Re-layout the script before trusting it here."
done

# Everything below is expressed relative to / because tar runs with -C / and
# du runs with cwd=/ — keep the two in lockstep.
SRV_REL="${SRV#/}"
REPO_REL="${REPO_ROOT#/}"
REPOS_REL="${REPOS_DIR%/}"; REPOS_REL="${REPOS_REL#/}"
DATA_REL="${DATA_DIR%/}";   DATA_REL="${DATA_REL#/}"
HOME_REL="${DHOME%/}";      HOME_REL="${HOME_REL#/}"
ROOT_REL="$(getent passwd root | cut -d: -f6)"; ROOT_REL="${ROOT_REL#/}"
WWW_REL="${WWW_ROOT#/}"

# --- verify mode ------------------------------------------------------------
if [[ "$MODE" == verify ]]; then
    [[ -n "$BUNDLE" ]] || die "--verify needs a bundle directory"
    [[ -d "$BUNDLE" ]] || die "not a directory: $BUNDLE"
    [[ -f "$BUNDLE/checksums.sha256" ]] || die "no checksums.sha256 in $BUNDLE"
    step "verifying $BUNDLE"
    if (cd "$BUNDLE" && sha256sum -c --quiet checksums.sha256); then
        ok "all checksums match — bundle is intact"
        log "$(du -sh "$BUNDLE" | cut -f1)  $(find "$BUNDLE" -type f | wc -l) files"
    else
        die "checksum mismatch — re-run the export, the bundle is corrupt"
    fi
    exit 0
fi

# --- bundle skeleton --------------------------------------------------------
if (( DRY_RUN )); then
    BUNDLE="$MIGRATE_ROOT/bundle-<stamp>"
elif [[ -d "$MIGRATE_ROOT/archives" && -f "$MIGRATE_ROOT/checksums.sha256" ]]; then
    # Re-running against an existing bundle refreshes the manifest, meta/ and
    # RESTORE.md in place. Archives that already exist are skipped (--force
    # redoes them), so this is cheap.
    BUNDLE="$MIGRATE_ROOT"
    log "reusing existing bundle: $BUNDLE"
else
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BUNDLE="$MIGRATE_ROOT/bundle-$STAMP"
    install -d -m 700 "$BUNDLE/archives" "$BUNDLE/db" "$BUNDLE/system" "$BUNDLE/meta"
    # install -d leaves intermediate dirs at the ambient umask; the bundle root
    # is the parent of every credential, so tighten it explicitly.
    chmod 700 "$BUNDLE"
fi

# --- exclusion list ---------------------------------------------------------
# Patterns are relative to / — tar runs with -C /, du runs with cwd=/.
EXCLUDE_FILE="$(mktemp)"
trap 'rm -f "$EXCLUDE_FILE"' EXIT

cat > "$EXCLUDE_FILE" <<EOF
${DATA_REL}/backups
${DATA_REL}/migrate
${SRV_REL}/ojs-qa
${HOME_REL}/.nvm
${HOME_REL}/.npm
${HOME_REL}/.bun
${HOME_REL}/.cache
${HOME_REL}/.docker
${ROOT_REL}/.hermes/cache
${ROOT_REL}/.hermes/logs
${ROOT_REL}/.hermes/audio_cache
${ROOT_REL}/.hermes/image_cache
${ROOT_REL}/.hermes/.hermes_history
*.sock
${WWW_REL}/ojs/cache
${WWW_REL}/ojs-files/scheduledTaskLogs
${WWW_REL}/ojs-files/usageStats
EOF

if (( INCLUDE_OLD_BACKUPS )); then sed -i "\#^${DATA_REL}/backups\$#d" "$EXCLUDE_FILE"; fi
if (( KEEP_OJS_LOGS ));       then
    sed -i "/ojs-files\/scheduledTaskLogs/d;/ojs-files\/usageStats/d" "$EXCLUDE_FILE"
fi
if (( LEAN )); then
    cat >> "$EXCLUDE_FILE" <<EOF
${HOME_REL}/.local
${HOME_REL}/.claude
${HOME_REL}/.gemini
${HOME_REL}/bec-bundle
${HOME_REL}/biadenrekacipta-vps-*.tar.gz
EOF
fi

# Rebuildable build output — only reachable from the repo checkouts, so the
# pattern can never swallow a hand-written source tree (e.g. stack/ojs/build).
if (( ! INCLUDE_BUILD )); then
    cat >> "$EXCLUDE_FILE" <<EOF
${REPOS_REL}/*/node_modules
${REPOS_REL}/*/.next
${REPOS_REL}/*/dist
${REPOS_REL}/*/vendor
${REPOS_REL}/*/bootstrap/cache
${REPOS_REL}/*/storage/framework/cache
${REPOS_REL}/*/storage/framework/views
${REPOS_REL}/*/storage/framework/sessions
${REPO_REL}/apps/trilux/node_modules
EOF
fi

log "exclusions written to $EXCLUDE_FILE ($(grep -c . "$EXCLUDE_FILE") rules)"

# Names used by the RESTORE.md template.
PG_DBS="${POSTGRES_DATABASES:-}"
MY_DBS="${MYSQL_DATABASES:-ojs_local}"
PG_DB_COUNT="$(printf '%s\n' $PG_DBS | grep -c . || true)"
if (( SKIP_OJS_QA )) || [[ ! -d "/$SRV_REL/ojs-qa" ]]; then
    OJS_QA_NOTE="\`${SRV_REL}/ojs-qa\` — **not** in this bundle"
else
    OJS_QA_NOTE="\`${SRV_REL}/ojs-qa\` — its own archive; restore with \`--with-ojs-qa\`"
fi

# --- helpers ----------------------------------------------------------------
pack() {
    # pack <relpath-in-archives> <description> <member...>
    # Set PACK_EXCLUDE_FILE to use a different exclusion list for one call.
    local rel="$1" desc="$2"; shift 2
    local out="$BUNDLE/archives/$rel"
    local excl="${PACK_EXCLUDE_FILE:-$EXCLUDE_FILE}"
    local members=() m
    for m in "$@"; do
        if [[ -e "/$m" ]]; then members+=("$m"); else warn "missing, skipped: /$m"; fi
    done
    if [[ ${#members[@]} -eq 0 ]]; then warn "nothing to pack for $rel"; return 0; fi

    if (( DRY_RUN )); then
        local bytes
        bytes="$(cd / && du -scb --exclude-from="$excl" "${members[@]}" 2>/dev/null \
                 | tail -1 | cut -f1)"
        printf '%s\n' "    ${C_BOLD}${rel}${C_RESET}  ~$(_human "${bytes:-0}")  (${desc})"
        return 0
    fi

    if [[ -s "$out" && $FORCE -eq 0 ]]; then
        ok "$rel — exists, skipped (--force to redo)"
        return 0
    fi
    info "packing $rel — $desc"
    tar --zstd -cf "$out" \
        --warning=no-file-changed \
        --exclude-from="$excl" \
        -C / "${members[@]}" 2>/dev/null \
        || warn "tar exited non-zero for $rel — a live file changed while being read (agent DBs, caches). Re-run before the final cutover if it matters."
    chmod 600 "$out"
    ok "$rel  $(du -h "$out" | cut -f1)  (${desc})"
}

_human() {
    awk -v b="$1" 'BEGIN{
        split("B KiB MiB GiB TiB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%.0f %s" : "%.2f %s"), b, u[i]
    }'
}

# --- the plan ---------------------------------------------------------------
step "migration export"
log "source      : $(hostname)  ($(curl -s -m 5 ifconfig.me 2>/dev/null || echo 'ip unknown'))"
log "destination : $BUNDLE"
log "target user : $DEPLOY  (home $DHOME)"
log "packing     : $SRV  (repo root $REPO_ROOT)"

step "archives"
pack srv.tar.zst       "$SRV — repo checkouts, HQ, notes, skills vault, vps-plus + its .env files" \
                       "$SRV_REL"
pack home-deploy.tar.zst "$DHOME — agent configs, SSH keys, bec-repo, bec-bundle, project dirs" \
                       "$HOME_REL"
pack hermes-root.tar.zst "/$ROOT_REL — the ACTIVE hermes gateway (.hermes, .ssh)" \
                       "$ROOT_REL/.hermes" "$ROOT_REL/.ssh" "$ROOT_REL/.bashrc" \
                       "$ROOT_REL/.gitconfig" "$ROOT_REL/.profile"
pack www-ojs.tar.zst   "the OJS web tree + user uploads (config.inc.php included)" \
                       "${WWW_ROOT#/}"
pack etc-system.tar.zst "nginx, TLS certs, AppArmor, systemd units, docker, fail2ban, crontab" \
                       "etc/nginx" "etc/letsencrypt" "etc/apparmor.d/local" \
                       "etc/systemd/system/mysql.service.d" \
                       "etc/systemd/system/filebrowser.service" \
                       "etc/systemd/system/filebrowser.service.d" \
                       "etc/systemd/system/ojs-queue.service" \
                       "etc/systemd/system/ojs-scheduler.service" \
                       "etc/docker/daemon.json" "etc/fail2ban/jail.d" \
                       "etc/filebrowser" "var/spool/cron/crontabs" "etc/cron.d" \
                       "etc/php/8.3/fpm/pool.d" "etc/php/8.4/fpm/pool.d"

# /srv/ojs-qa is a self-contained QA staging instance: containers dead for days,
# MySQL volume orphaned. Its unique value is the client reports, the audit
# scripts, the E2E harness and the seeded data — the OJS/ojs-git checkouts
# inside it are re-clonable, and so is e2e/node_modules. Packed as its OWN
# archive so the main restore never pays for it; migrate-import.sh unpacks it
# only with --with-ojs-qa.
if (( ! SKIP_OJS_QA )) && [[ -d "/$SRV_REL/ojs-qa" ]]; then
    OJSQA_EXCL="$(mktemp)"
    printf '%s\n' "${SRV_REL}/ojs-qa/e2e/node_modules" > "$OJSQA_EXCL"
    PACK_EXCLUDE_FILE="$OJSQA_EXCL" pack ojs-qa.tar.zst \
        "/$SRV_REL/ojs-qa — QA staging instance: reports, audit scripts, E2E harness, seed data" \
        "$SRV_REL/ojs-qa"
    PACK_EXCLUDE_FILE=""
    rm -f "$OJSQA_EXCL"
fi

# --- databases --------------------------------------------------------------
step "databases"
if (( DRY_RUN )); then
    for db in ${POSTGRES_DATABASES:-}; do
        printf '    %s\n' "db/postgres-${db}.sql.gz  (postgres: ${db})"
    done
    for db in ${MYSQL_DATABASES:-ojs_local}; do
        printf '    %s\n' "db/mysql-${db}.sql.gz  (mysql: ${db})"
    done
else
    if docker exec vpsplus-postgres pg_isready -U "${POSTGRES_USER:-vpsplus}" >/dev/null 2>&1; then
        for db in ${POSTGRES_DATABASES:-}; do
            out="$BUNDLE/db/postgres-${db}.sql.gz"
            docker exec vpsplus-postgres pg_dump \
                -U "${POSTGRES_USER:-vpsplus}" --clean --if-exists --no-owner "$db" \
                | gzip -9 > "$out"
            chmod 600 "$out"
            ok "postgres-${db}.sql.gz  $(du -h "$out" | cut -f1)"
        done
    else
        die "postgres is not running — start the stack, then re-run (db dumps are mandatory)"
    fi

    if command -v mysql >/dev/null 2>&1 && mysqladmin ping >/dev/null 2>&1; then
        for db in ${MYSQL_DATABASES:-ojs_local}; do
            out="$BUNDLE/db/mysql-${db}.sql.gz"
            mysqldump --single-transaction --quick --routines --triggers \
                --databases "$db" 2>/dev/null | gzip -9 > "$out"
            chmod 600 "$out"
            ok "mysql-${db}.sql.gz  $(du -h "$out" | cut -f1)"
        done
    else
        die "mysql is not running — start it, then re-run (ojs_local is NOT in postgres)"
    fi
fi

# --- machine + system facts -------------------------------------------------
if (( ! DRY_RUN )); then
    step "system facts"

    {
        echo "hostname      : $(hostname)"
        echo "exported at   : $(date -Iseconds)"
        echo "exported by   : $(whoami)@$(hostname)"
        echo "os            : $(. /etc/os-release; echo "$PRETTY_NAME")"
        echo "kernel        : $(uname -r)"
        echo "arch          : $(uname -m)"
        echo "cpus          : $(nproc)"
        echo "memory        : $(free -h | awk '/^Mem:/{print $2}')"
        echo "public ip     : $(curl -s -m 5 ifconfig.me 2>/dev/null || echo unknown)"
        echo "timezone      : $(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
        echo "deploy user   : $DEPLOY ($(id "$DEPLOY" 2>/dev/null || echo 'MISSING'))"
        echo "srv parent    : $SRV"
        echo "repo root     : $REPO_ROOT"
        echo "repos dir     : ${REPOS_DIR:-}"
        echo "data dir      : ${DATA_DIR:-}"
        echo "www ojs       : $WWW_ROOT"
        echo "postgres dbs  : ${POSTGRES_DATABASES:-}"
        echo "mysql dbs     : ${MYSQL_DATABASES:-ojs_local}"
        echo "domains       : $(grep -hE '^DOMAIN_[A-Z]+=' "$ROOT/vps.conf" 2>/dev/null | cut -d= -f2- | cut -d'#' -f1 | tr -s ' ' | tr '\n' ' ')"
    } > "$BUNDLE/meta/machine.txt"

    need_cmd ss >/dev/null 2>&1 || true
    {
        echo "# listening sockets on the OLD box (reference only)"
        ss -tulpn 2>/dev/null | tail -n +2
    } > "$BUNDLE/meta/ports.txt"

    {
        echo "# docker images that must exist on the new box"
        docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | sort
    } > "$BUNDLE/meta/docker-images.txt"

    {
        echo "# systemd units enabled on the old box"
        systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}'
    } > "$BUNDLE/meta/systemd-enabled.txt"

    {
        echo "# packages — restore with: dpkg --set-selections < dpkg-selections.txt && apt-get dselect-upgrade -y"
        dpkg --get-selections | awk '$2 == "install"'
    } > "$BUNDLE/meta/dpkg-selections.txt"

    {
        echo "# firewall — re-apply with: ufw reset && bash system/ufw-apply.sh"
        ufw status verbose 2>/dev/null
    } > "$BUNDLE/meta/ufw-status.txt"

    ufw show added 2>/dev/null | grep '^ufw ' > "$BUNDLE/system/ufw-apply.sh" || true
    if [[ -s "$BUNDLE/system/ufw-apply.sh" ]]; then
        { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail';
          echo '# regenerated by ops/migrate-export.sh — default-deny is assumed to already be set';
          cat "$BUNDLE/system/ufw-apply.sh"; } > "$BUNDLE/system/ufw-apply.sh.tmp"
        mv "$BUNDLE/system/ufw-apply.sh.tmp" "$BUNDLE/system/ufw-apply.sh"
        chmod 700 "$BUNDLE/system/ufw-apply.sh"
        ok "system/ufw-apply.sh  ($(grep -c '^ufw ' "$BUNDLE/system/ufw-apply.sh") rules)"
    fi

    # Git state — so the new box can prove its checkouts match the old box.
    : > "$BUNDLE/meta/git-state.txt"
    for d in "${REPOS_DIR:-}/"* "$REPO_ROOT" "$DHOME/bec-repo" "$WWW_ROOT"; do
        [[ -d "$d/.git" ]] || continue
        {
            echo "== $d"
            sudo -u "$DEPLOY" git -C "$d" remote -v 2>/dev/null | head -1 || true
            git -C "$d" log -1 --format='   HEAD %h  %ad  %s' --date=short 2>/dev/null || true
            git -C "$d" status --porcelain 2>/dev/null | head -20 || true
        } >> "$BUNDLE/meta/git-state.txt"
    done

    # Credential files — PATHS ONLY, never values. Listed from the source box,
    # not by searching the bundle: the secrets live INSIDE the archives.
    {
        echo "# files in this bundle that hold live credentials (paths only)"
        for f in "$REPO_ROOT/vps.conf" "$REPO_ROOT/stack/stack.env" \
                 "$REPO_ROOT"/stack/apps/*.env "$REPO_ROOT/apps/supabase/supabase.env" \
                 "$DHOME/.ssh"/id_* "$DHOME/.claude.json" \
                 "/$ROOT_REL/.hermes/.env" "/$ROOT_REL/.hermes/auth.json"; do
            [[ -e "$f" ]] && echo "${f#/}"
        done
        find "${REPOS_DIR:-/nonexistent}" -maxdepth 3 -name '.env*' ! -name '*.example' 2>/dev/null \
            | sed 's#^/##' | sort
        echo "etc/letsencrypt/live/*/privkey.pem"
        echo "db/*.sql.gz   (dump contents include password hashes)"
    } > "$BUNDLE/meta/credentials.txt"

    ok "meta/ written ($(find "$BUNDLE/meta" -type f | wc -l) files)"
fi

# --- restore notes ----------------------------------------------------------
if (( ! DRY_RUN )); then
    step "restore notes"
    ARCH_LIST="$(cd "$BUNDLE/archives" && for f in *.tar.zst; do
        printf '| `%s` | %s |\n' "$f" "$(du -h "$f" | cut -f1)"
    done)"

    cat > "$BUNDLE/RESTORE.md" <<EOF
# Restore this bundle

Built **$(date -Iseconds)** on \`$(hostname)\` (source OS: $(. /etc/os-release; echo "$PRETTY_NAME")).
Bundle size: **$(du -sh "$BUNDLE" | cut -f1)** across $(find "$BUNDLE" -type f | wc -l) files.

Contents are **plaintext credentials**. Keep this directory mode 700 and shred
it on both boxes when the migration is signed off.

## 1. Verify it survived the trip

\`\`\`
cd <this bundle>
sha256sum -c checksums.sha256
\`\`\`

## 2. What is inside

| archive | size |
|---|---|
${ARCH_LIST}

- \`srv/\`, \`home/\`, \`root/\`, \`var/www\` map straight onto \`/\` — extracted with \`tar --zstd -xf <file> -C /\`
- \`db/\` holds **${PG_DB_COUNT} Postgres dumps** (\`${PG_DBS}\`) **and MySQL** \`${MY_DBS}\`
- \`meta/\` is reference only: machine facts, ports, packages, git state, credentials index
- \`system/ufw-apply.sh\` re-applies the firewall rules additively

## 3. What is NOT inside (rebuild or re-pull)

- docker **images** (~20 GB, incl. ollama) — re-pulled
- docker **build cache** (~38 GB) — app images are rebuilt
- \`node_modules\`, \`.next\`, \`dist\`, \`vendor\` — reinstalled by \`bootstrap.sh\` / \`ops/deploy-*.sh\`
- the Ollama **model volume** (~2 GB) — re-pulled on first use
- the MySQL **datadir** — restored from \`db/mysql-*.sql.gz\`, not copied file-by-file
- ${OJS_QA_NOTE}

## 4. Restore order

This bundle restores **data and config only**. The runtime comes from
\`bootstrap.sh\`. Interleave them exactly like this:

\`\`\`
cd /srv/vps-plus
./bootstrap.sh 00-base 10-docker 20-node
./ops/migrate-import.sh <this bundle> --only files,system
./bootstrap.sh 60-postgres
./ops/migrate-import.sh <this bundle> --only db
./bootstrap.sh 70-apps 80-nginx 90-tls
./ops/migrate-import.sh <this bundle> --only ownership,verify
\`\`\`

## 5. Start what bootstrap does not know about

\`\`\`
docker compose -f stack/ojs/docker-compose.yml up -d --build
systemctl start mysql ojs-queue ojs-scheduler

docker compose -f apps/supabase.compose.yml \\
    --env-file apps/supabase/supabase.env up -d
\`\`\`

## 6. Cutover

Full sequence in \`docs/MIGRATION.md\` ("Phase 4 — cutover"). The two rules that
bite hardest:

1. **Stop the gateway on the OLD box before starting it here.** One bot token =
   one poller; two machines polling silently lose messages.
2. **Verify DNS on the authoritative nameserver**, not \`1.1.1.1\` — public
   resolvers hold the old TTL, the VPS's own resolver is instant.

Smoke-test every vhost through public HTTPS, not loopback.
EOF
    chmod 600 "$BUNDLE/RESTORE.md"
    ok "RESTORE.md written"
fi

# --- checksums --------------------------------------------------------------
if (( ! DRY_RUN )); then
    step "checksums"
    (cd "$BUNDLE" && find archives db -type f -print0 | sort -z \
        | xargs -0 sha256sum > checksums.sha256)
    ok "$(wc -l < "$BUNDLE/checksums.sha256") checksums written"
fi

# --- transfer helper --------------------------------------------------------
if (( ! DRY_RUN )); then
    cat > "$BUNDLE/transfer.sh" <<'EOS'
#!/usr/bin/env bash
# Push this bundle to the new VPS. Usage: ./transfer.sh <user@new-host>
set -euo pipefail
DEST="${1:?usage: ./transfer.sh user@new-vps-ip}"
HERE="$(cd "$(dirname "$0")" && pwd)"
echo ">> pushing $(du -sh "$HERE" | cut -f1) to $DEST ..."
rsync -avz --progress -e ssh "$HERE/" "$DEST:~/migrate-bundle/"
ssh "$DEST" "chmod -R go-rwx ~/migrate-bundle && ./migrate-bundle/verify-on-target.sh 2>/dev/null || true"
echo ">> done. On the new box: /srv/vps-plus/ops/migrate-import.sh ~/migrate-bundle"
EOS
    chmod 700 "$BUNDLE/transfer.sh"

    cat > "$BUNDLE/verify-on-target.sh" <<'EOS'
#!/usr/bin/env bash
# Verify the bundle arrived intact. Run on the NEW box, inside the bundle dir.
set -euo pipefail
cd "$(dirname "$0")"
sha256sum -c --quiet checksums.sha256 && echo "ok  bundle intact"
EOS
    chmod 700 "$BUNDLE/verify-on-target.sh"
fi

# --- summary ----------------------------------------------------------------
printf '\n'
if (( DRY_RUN )); then
    step "dry run complete — nothing was written"
    log "drop --dry-run to build the bundle"
    exit 0
fi

step "bundle ready"
TOTAL="$(du -sb "$BUNDLE" | cut -f1)"
ok "$BUNDLE"
log "size      : $(_human "$TOTAL")  ($(find "$BUNDLE" -type f | wc -l) files)"
log "checksums : sha256, $BUNDLE/checksums.sha256"
printf '\n'
warn "This bundle contains PLAINTEXT CREDENTIALS."
warn "  * it is mode 700 — keep it that way"
warn "  * move it with $BUNDLE/transfer.sh <user@new-vps>"
warn "  * shred it on BOTH boxes once the migration is signed off:"
warn "      shred -u -r $BUNDLE"
printf '\n'
log "next: RESTORE.md inside the bundle, or docs/MIGRATION.md in the repo"
