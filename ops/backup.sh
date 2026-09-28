#!/usr/bin/env bash
# Nightly-safe backup: every Postgres database plus the configuration that
# would take longest to recreate by hand.
#
#   ops/backup.sh                 write to $DATA_DIR/backups
#   ops/backup.sh --keep 30       change retention (default 14 days)
#
# Install as a cron job:
#   sudo crontab -e
#   15 3 * * *  /srv/vps-plus/ops/backup.sh >> /var/log/vps-plus-backup.log 2>&1
#
# This writes to the same disk as the data it is protecting, which does not
# survive losing the VPS. Sync $DATA_DIR/backups off-box (rclone, restic, or a
# plain scp from your laptop) before calling it a backup.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

KEEP_DAYS=14
if [[ "${1:-}" == "--keep" ]]; then KEEP_DAYS="$2"; fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$DATA_DIR/backups"
install -d -m 700 "$DEST"

# --- databases --------------------------------------------------------------
if docker exec vpsplus-postgres pg_isready -U "${POSTGRES_USER:-vpsplus}" >/dev/null 2>&1; then
    step "postgres"
    for db in ${POSTGRES_DATABASES:-}; do
        out="$DEST/db-${db}-${STAMP}.sql.gz"
        # Custom format would be smaller, but plain SQL can be restored with
        # psql alone — which matters when you are restoring at 2am.
        docker exec vpsplus-postgres pg_dump \
            -U "${POSTGRES_USER:-vpsplus}" --clean --if-exists "$db" \
            | gzip -9 > "$out"
        ok "$(basename "$out")  $(du -h "$out" | cut -f1)"
    done
else
    warn "postgres is not running — no database dump taken"
fi

# --- mysql (OJS) ------------------------------------------------------------
# OJS keeps its data in MySQL, not Postgres. Before this block existed ojs_local
# had NO dump at all and the live datadir (/var/lib/mysql-ojs) was the only
# copy — a lost VPS meant a lost journal. Never remove this section.
MYSQL_DATABASES="${MYSQL_DATABASES:-ojs_local}"
if command -v mysql >/dev/null 2>&1 && mysqladmin ping >/dev/null 2>&1; then
    step "mysql"
    for db in $MYSQL_DATABASES; do
        [[ -n "$db" ]] || continue
        out="$DEST/db-${db}-${STAMP}.sql.gz"
        mysqldump --single-transaction --quick --routines --triggers \
            --databases "$db" 2>/dev/null | gzip -9 > "$out"
        chmod 600 "$out"
        ok "$(basename "$out")  $(du -h "$out" | cut -f1)"
    done
else
    warn "mysql is not running — no MySQL dump taken (OJS data is NOT protected)"
fi

# --- configuration ----------------------------------------------------------
# The agent configs and the app env files. These hold live credentials, so the
# archive is 600 and never leaves $DATA_DIR unencrypted.
step "configuration"
HOME_DIR="$(deploy_home)"
CONF_OUT="$DEST/config-${STAMP}.tar.gz"

tar -czf "$CONF_OUT" \
    --warning=no-file-changed \
    --exclude='*.sock' \
    --exclude='*/state.db*' \
    --exclude='*/cache' \
    --exclude='*/logs' \
    --exclude='*/sessions' \
    --exclude='*/node_modules' \
    -C / \
    "${HOME_DIR#/}/.hermes" \
    "${HOME_DIR#/}/.claude" \
    "${HOME_DIR#/}/.gemini" \
    "${HOME_DIR#/}/.codex" \
    "root/.hermes" \
    "root/.ssh" \
    "${HOME_DIR#/}/.ssh" \
    "${SRV_ROOT#/}/stack/apps" \
    "${SRV_ROOT#/}/stack/stack.env" \
    "${SRV_ROOT#/}/vps.conf" \
    2>/dev/null || warn "tar exited non-zero for the config archive — a live file changed while being read (the gateway writes to root/.hermes). Re-run if it matters."

chmod 600 "$CONF_OUT"
ok "$(basename "$CONF_OUT")  $(du -h "$CONF_OUT" | cut -f1)"

# --- nginx + certs ----------------------------------------------------------
step "nginx + tls"
NGX_OUT="$DEST/nginx-${STAMP}.tar.gz"
# sites-enabled is included on purpose: the symlinks are what actually make a
# vhost live, and `bootstrap.sh 80-nginx` only re-creates links for APP_KEYS —
# so a vhost outside APP_KEYS (plus-office) exists ONLY if it travels here.
tar -czf "$NGX_OUT" \
    /etc/nginx/sites-available \
    /etc/nginx/sites-enabled \
    /etc/nginx/conf.d \
    /etc/nginx/nginx.conf \
    /etc/nginx/ssl \
    /etc/letsencrypt 2>/dev/null || true
chmod 600 "$NGX_OUT"
ok "$(basename "$NGX_OUT")  $(du -h "$NGX_OUT" | cut -f1)"

# --- system configuration ---------------------------------------------------
# Everything hand-edited that a plain Ubuntu reinstall would NOT give back:
# AppArmor local overrides (the OJS MySQL datadir lives outside /var/lib/mysql),
# systemd drop-ins, the custom units, docker daemon.json, fail2ban jails, the
# root crontab and the filebrowser DB.
step "system config"
SYS_OUT="$DEST/system-${STAMP}.tar.gz"
tar -czf "$SYS_OUT" \
    --warning=no-file-changed \
    /etc/apparmor.d/local \
    /etc/systemd/system/mysql.service.d \
    /etc/systemd/system/filebrowser.service.d \
    /etc/systemd/system/filebrowser.service \
    /etc/systemd/system/ojs-queue.service \
    /etc/systemd/system/ojs-scheduler.service \
    /etc/docker/daemon.json \
    /etc/fail2ban/jail.d \
    /etc/filebrowser \
    /var/spool/cron/crontabs \
    2>/dev/null || warn "tar reported missing paths (usually harmless)"
chmod 600 "$SYS_OUT"
ok "$(basename "$SYS_OUT")  $(du -h "$SYS_OUT" | cut -f1)"

# --- retention --------------------------------------------------------------
step "retention"
removed="$(find "$DEST" -maxdepth 1 -type f -mtime "+${KEEP_DAYS}" -print -delete | wc -l)"
log "deleted $removed archive(s) older than ${KEEP_DAYS} days"
log "$DEST now holds $(find "$DEST" -maxdepth 1 -type f | wc -l) files, $(du -sh "$DEST" | cut -f1)"

printf '\n'
warn "This backup lives on the same disk as the data. Copy it off the VPS:"
warn "  rsync -avz ${DEPLOY_USER}@<vps-ip>:${DEST}/ ./vps-backups/"
