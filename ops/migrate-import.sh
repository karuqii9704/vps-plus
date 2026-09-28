#!/usr/bin/env bash
# migrate-import.sh — restore a bundle produced by ops/migrate-export.sh.
#
#   ops/migrate-import.sh ~/migrate-bundle
#
#   --only <phases>   comma-separated subset, in this order:
#                       files       unpack /srv, the deploy home, /root/.hermes, the OJS web tree
#                       system      unpack nginx, TLS, AppArmor, systemd, docker, fail2ban, crontab
#                       db          restore every Postgres db + the MySQL OJS db
#                       ownership   fix owners/modes (deploy user, www-data, root)
#                       verify      assert the result and print what is left to do
#                     default: all
#   --dry-run         print what would happen, touch nothing
#   --no-verify       skip the sha256 check of the bundle first
#   --force           re-extract archives even if the target already has content
#   --with-ojs-qa     also unpack /srv/ojs-qa (the QA staging instance)
#
# THIS SCRIPT IS NOT A COMPLETE MIGRATION. It restores DATA and CONFIG only.
# The runtime (docker, node, images, containers, nginx vhosts enabled, TLS) is
# built by bootstrap.sh. Correct order on a fresh box:
#
#   1. git clone <vps-plus> /srv/vps-plus
#   2. ./bootstrap.sh 00-base 10-docker 20-node
#   3. ./ops/migrate-import.sh <bundle> --only files,system
#   4. ./bootstrap.sh 60-postgres
#   5. ./ops/migrate-import.sh <bundle> --only db
#   6. ./bootstrap.sh 70-apps 80-nginx 90-tls
#   7. ./ops/migrate-import.sh <bundle> --only ownership,verify
#
# Full checklist: docs/MIGRATION.md

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

ONLY="all"
DRY_RUN=0
DO_VERIFY=1
FORCE=0
WITH_OJS_QA=0
BUNDLE=""

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)      ONLY="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --no-verify) DO_VERIFY=0; shift ;;
        --force)     FORCE=1; shift ;;
        --with-ojs-qa) WITH_OJS_QA=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "unknown option: $1 (try --help)" ;;
        *)           BUNDLE="$1"; shift ;;
    esac
done

need_root
[[ -n "$BUNDLE" ]] || die "usage: migrate-import.sh <bundle-dir> [--only phases]"
BUNDLE="$(cd "$BUNDLE" && pwd)"
[[ -d "$BUNDLE/archives" ]] || die "not a migration bundle (no archives/): $BUNDLE"

phase_enabled() { [[ "$ONLY" == "all" || ",$ONLY," == *",$1,"* ]]; }

run() {
    if (( DRY_RUN )); then printf '   \033[2mwould run:\033[0m %s\n' "$*"; else "$@"; fi
}

# --- facts from the bundle (the new box has no vps.conf yet) ----------------
meta() { grep -m1 "^$1" "$BUNDLE/meta/machine.txt" 2>/dev/null | sed 's/^[^:]*: *//; s/ *(.*//'; }

DEPLOY="$(meta 'deploy user')"       ; DEPLOY="${DEPLOY:-plus}"
SRV="$(meta 'srv parent')"           ; SRV="${SRV:-/srv}"
REPO_ROOT="$(meta 'repo root')"      ; REPO_ROOT="${REPO_ROOT:-$SRV/vps-plus}"
REPOS_DIR="$(meta 'repos dir')"      ; REPOS_DIR="${REPOS_DIR:-$SRV/repos}"
DATA_DIR="$(meta 'data dir')"        ; DATA_DIR="${DATA_DIR:-$SRV/data}"
PG_USER=postgres
MYSQL_DATADIR=/var/lib/mysql-ojs
OJS_DIR=/var/www/biadenrekacipta/ojs
OJS_FILES=/var/www/biadenrekacipta/ojs-files

# vps.conf may exist (if `files` already ran) — prefer it for the db list.
PG_DBS="$(meta 'postgres dbs')"
MY_DBS="$(meta 'mysql dbs')"         ; MY_DBS="${MY_DBS:-ojs_local}"
if [[ -f "$ROOT/vps.conf" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/lib/common.sh" >/dev/null 2>&1 || true
    load_conf "$ROOT" >/dev/null 2>&1 || true
    PG_DBS="${POSTGRES_DATABASES:-$PG_DBS}"
    MY_DBS="${MYSQL_DATABASES:-$MY_DBS}"
    PG_USER="${POSTGRES_USER:-postgres}"
fi

BUNDLE_SIZE="$(du -sh "$BUNDLE" | cut -f1)"

# --- 0. preflight -----------------------------------------------------------
step "preflight"
log "bundle      : $BUNDLE  ($BUNDLE_SIZE)"
log "deploy user : $DEPLOY"
log "srv root    : $SRV"
log "postgres    : ${PG_DBS:-<none>}"
log "mysql       : ${MY_DBS:-<none>}"

if [[ "$(meta 'os')" != *"$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")"* ]] 2>/dev/null; then
    warn "OS differs from the source box ($(meta 'os')) — package versions may drift"
fi

if (( DO_VERIFY )); then
    if (cd "$BUNDLE" && sha256sum -c --quiet checksums.sha256 2>/dev/null); then
        ok "bundle checksums verified"
    else
        die "checksum mismatch — re-transfer the bundle, or pass --no-verify to override"
    fi
fi

command -v zstd >/dev/null 2>&1 || {
    warn "zstd not installed — installing"
    run apt-get update -qq && run apt-get install -y -qq zstd
}

if ! getent passwd "$DEPLOY" >/dev/null 2>&1; then
    warn "user '$DEPLOY' does not exist yet — run 'bootstrap.sh 00-base' first"
fi

# --- helpers ----------------------------------------------------------------
unpack() {
    # unpack <archive-file> [paths to restore...]
    local file="$BUNDLE/archives/$1"; shift
    [[ -f "$file" ]] || { warn "absent, skipped: $1"; return 0; }
    if (( DRY_RUN )); then
        printf '   \033[2mwould unpack:\033[0m %-22s -> /%s\n' "$(basename "$file")" "$*"
        return 0
    fi
    info "unpacking $(basename "$file")  ($(du -h "$file" | cut -f1))"
    if [[ $# -gt 0 ]]; then
        tar --zstd -xf "$file" -C / "$@"
    else
        tar --zstd -xf "$file" -C /
    fi
}

# --- 1. files ---------------------------------------------------------------
if phase_enabled files; then
    step "files"
    unpack srv.tar.zst
    unpack home-deploy.tar.zst
    unpack hermes-root.tar.zst
    unpack www-ojs.tar.zst
    unpack usr-local.tar.zst
    if (( WITH_OJS_QA )); then
        unpack ojs-qa.tar.zst
    elif [[ -f "$BUNDLE/archives/ojs-qa.tar.zst" ]]; then
        log "ojs-qa.tar.zst is in the bundle but NOT restored — pass --with-ojs-qa to unpack it"
    fi
    if (( ! DRY_RUN )); then
        # The hand-rolled symlink OJS ships with: ojs-3.5.0-5 -> ojs
        [[ -d "$OJS_DIR" && ! -e "$(dirname "$OJS_DIR")/ojs-3.5.0-5" ]] \
            && ln -sfn "$OJS_DIR" "$(dirname "$OJS_DIR")/ojs-3.5.0-5" \
            && ok "relinked ojs-3.5.0-5 -> $OJS_DIR"
        ok "files restored"
    fi
fi

# --- 2. system --------------------------------------------------------------
if phase_enabled system; then
    step "system config"
    unpack etc-system.tar.zst
    if (( ! DRY_RUN )); then
        # AppArmor: the OJS MySQL datadir is outside /var/lib/mysql, so the
        # stock profile denies it. The local override came in with the archive.
        if [[ -f /etc/apparmor.d/usr.sbin.mysqld ]]; then
            run apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
                && ok "AppArmor mysqld profile reloaded" \
                || warn "apparmor_parser failed — check /etc/apparmor.d/local/usr.sbin.mysqld"
        fi
        run systemctl daemon-reload && ok "systemd reloaded"

        # The Hermes gateway is a systemd --USER unit for root, NOT a system
        # unit — nothing in systemctl's normal view shows it. Both the unit and
        # its WantedBy symlink travel in the archive; what is missing on a fresh
        # box is linger (so the user manager survives logout) and a user manager
        # to load the unit at all. Without this the gateway never comes back.
        if [[ -f /root/.config/systemd/user/hermes-gateway.service ]]; then
            if (( DRY_RUN )); then
                printf '   \033[2mwould run:\033[0m loginctl enable-linger root\n'
                printf '   \033[2mwould run:\033[0m XDG_RUNTIME_DIR=/run/user/0 systemctl --user daemon-reload\n'
            else
                loginctl enable-linger root 2>/dev/null \
                    && ok "linger enabled for root" \
                    || warn "could not enable linger — the gateway will not start at boot"
                for _ in $(seq 1 10); do [[ -d /run/user/0 ]] && break; sleep 1; done
                if [[ -d /run/user/0 ]]; then
                    XDG_RUNTIME_DIR=/run/user/0 systemctl --user daemon-reload 2>/dev/null \
                        && ok "systemd --user reloaded (hermes-gateway registered)" \
                        || warn "systemctl --user failed — start the gateway by hand after login"
                else
                    warn "no user manager at /run/user/0 — linger will start it on the next boot"
                fi
            fi
        fi

        # Firewall: apply ADDITIVELY from the recorded rules. Never reset here —
        # a reset in the wrong moment drops the SSH rule and locks you out.
        if [[ -x "$BUNDLE/system/ufw-apply.sh" ]]; then
            if (( DRY_RUN )); then
                printf '   \033[2mwould apply:\033[0m %s\n' "$(grep -c '^ufw ' "$BUNDLE/system/ufw-apply.sh") ufw rules"
            else
                bash "$BUNDLE/system/ufw-apply.sh" >/dev/null 2>&1 \
                    && ok "ufw rules re-applied (additive)" \
                    || warn "some ufw rules failed — compare with meta/ufw-status.txt"
            fi
        fi

        # Enable the custom units that came along.
        for u in filebrowser ojs-queue ojs-scheduler; do
            if [[ -f "/etc/systemd/system/${u}.service" ]]; then
                run systemctl enable "$u" >/dev/null 2>&1 && ok "enabled $u" || true
            fi
        done

        if command -v nginx >/dev/null 2>&1; then
            # Vhosts arrive in sites-available; the symlinks are re-made by
            # bootstrap stage 80-nginx. Test now, do not die on a missing root.
            if nginx -t >/dev/null 2>&1; then
                ok "nginx -t clean"
            else
                warn "nginx -t reports errors — expected until stage 80-nginx recreates the vhosts"
            fi
        fi
        ok "system config restored"
    fi
fi

# --- 3. databases -----------------------------------------------------------
if phase_enabled db; then
    step "databases"

    # --- postgres ---
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx vpsplus-postgres; then
        warn "vpsplus-postgres is not running — run 'bootstrap.sh 60-postgres' first, then re-run --only db"
    else
        # Supabase's roles must exist before the plusthesite dump (it owns the
        # auth/ and storage/ schemas) can be replayed.
        ROLES="$ROOT/apps/supabase/roles.sql"
        if [[ -f "$ROLES" ]]; then
            info "ensuring supabase roles exist"
            if (( DRY_RUN )); then
                printf '   \033[2mwould run:\033[0m docker exec -i vpsplus-postgres psql -U %s -d postgres -q < apps/supabase/roles.sql\n' "$PG_USER"
            elif docker exec -i vpsplus-postgres psql -U "$PG_USER" -d postgres -q < "$ROLES"; then
                ok "roles.sql applied"
            else
                warn "roles.sql reported errors (may be benign if the roles already exist)"
            fi
        fi

        for db in $PG_DBS; do
            f="$BUNDLE/db/postgres-${db}.sql.gz"
            [[ -f "$f" ]] || { warn "no dump for $db — skipped"; continue; }
            if (( DRY_RUN )); then
                printf '   \033[2mwould restore:\033[0m postgres db %-14s (%s)\n' "$db" "$(du -h "$f" | cut -f1)"
                continue
            fi
            info "restoring postgres:$db"
            docker exec -i vpsplus-postgres psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 -q \
                < <(zcat "$f") >/dev/null 2>&1 \
                && ok "postgres:$db restored" \
                || warn "postgres:$db reported errors — verify manually"
        done

        # PostgREST caches the schema; a restore changes it.
        if docker ps --format '{{.Names}}' | grep -qx vpsplus-supabase-rest; then
            if (( DRY_RUN )); then
                printf '   \033[2mwould run:\033[0m docker restart vpsplus-supabase-rest\n'
            else
                docker restart vpsplus-supabase-rest >/dev/null \
                    && ok "postgrest restarted (schema cache dropped)" \
                    || warn "could not restart vpsplus-supabase-rest"
            fi
        fi
    fi

    # --- mysql (OJS) ---
    if ! command -v mysql >/dev/null 2>&1; then
        warn "mysql client absent — install mysql-server first (docs/MIGRATION.md, phase db)"
    else
        # Custom datadir: the box moved MySQL out of /var/lib/mysql entirely and
        # carries a systemd override + AppArmor exception to match.
        if [[ ! -s "$MYSQL_DATADIR/ibdata1" ]]; then
            warn "MySQL datadir $MYSQL_DATADIR is empty"
            if (( DRY_RUN )); then
                printf '   \033[2mwould run:\033[0m mysqld --initialize-insecure --datadir=%s\n' "$MYSQL_DATADIR"
            else
                read -r -p "   Initialize a fresh MySQL datadir at $MYSQL_DATADIR? [y/N] " a
                if [[ "${a,,}" == y* ]]; then
                    install -d -o mysql -g mysql -m 750 "$MYSQL_DATADIR"
                    mysqld --initialize-insecure --user=mysql --datadir="$MYSQL_DATADIR" \
                        && ok "datadir initialized (root has no password — set one!)"
                else
                    warn "skipped — MySQL restore will not work until the datadir exists"
                fi
            fi
        fi

        if (( ! DRY_RUN )) && command -v mysqladmin >/dev/null 2>&1 && mysqladmin ping >/dev/null 2>&1; then
            for db in $MY_DBS; do
                f="$BUNDLE/db/mysql-${db}.sql.gz"
                [[ -f "$f" ]] || { warn "no dump for $db — skipped"; continue; }
                info "restoring mysql:$db"
                zcat "$f" | mysql && ok "mysql:$db restored" || warn "mysql:$db reported errors"
            done

            # The application user is NOT inside a --databases dump: mysqldump
            # never emits CREATE USER. Recreate it from the OJS config, which
            # does travel in www-ojs.tar.zst.
            CFG="$OJS_DIR/config.inc.php"
            if [[ -f "$CFG" ]]; then
                APP_USER="$(grep -m1 -E '^[[:space:]]*username[[:space:]]*=' "$CFG" | sed -E 's/[^=]*=[[:space:]]*"?([^";]*)"?.*/\1/')"
                APP_PASS="$(grep -m1 -E '^[[:space:]]*password[[:space:]]*=' "$CFG" | sed -E 's/[^=]*=[[:space:]]*"?([^";]*)"?.*/\1/')"
                APP_DB="$(grep -m1 -E '^[[:space:]]*name[[:space:]]*=' "$CFG" | sed -E 's/[^=]*=[[:space:]]*"?([^";]*)"?.*/\1/')"
                if [[ -n "$APP_USER" && -n "$APP_PASS" ]]; then
                    if (( DRY_RUN )); then
                        printf '   \033[2mwould create:\033[0m mysql user %s@127.0.0.1 with GRANT ALL on %s.*\n' "$APP_USER" "$APP_DB"
                    else
                        mysql <<SQL && ok "mysql user $APP_USER@127.0.0.1 ready on $APP_DB" \
                            || warn "could not create $APP_USER — check the password in config.inc.php"
CREATE USER IF NOT EXISTS '$APP_USER'@'127.0.0.1' IDENTIFIED BY '$APP_PASS';
ALTER USER '$APP_USER'@'127.0.0.1' IDENTIFIED BY '$APP_PASS';
GRANT ALL PRIVILEGES ON \`$APP_DB\`.* TO '$APP_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
                    fi
                else
                    warn "could not parse db credentials from $CFG — create the user by hand"
                fi
            fi
        elif (( ! DRY_RUN )); then
            warn "mysql is not running — start it (systemctl start mysql) and re-run --only db"
        fi
    fi
fi

# --- 4. ownership -----------------------------------------------------------
if phase_enabled ownership; then
    step "ownership"
    if (( DRY_RUN )); then
        printf '   \033[2mwould chown:\033[0m %s -> %s:%s   |   %s -> www-data:www-data   |   /root/.hermes -> root\n' \
            "$SRV" "$DEPLOY" "$DEPLOY" "/var/www/biadenrekacipta"
    elif getent passwd "$DEPLOY" >/dev/null 2>&1; then
        chown -R "$DEPLOY:$DEPLOY" "$SRV" "/home/$DEPLOY" 2>/dev/null || true
        ok "$SRV and /home/$DEPLOY -> $DEPLOY"

        # Undo the part of that blanket chown which breaks the Laravel/FPM app.
        # Its container runs as uid 33, so storage/ + bootstrap/cache/ must stay
        # www-data:www-data and .env must be readable by www-data (0640).
        # Getting this wrong is SILENT: the site keeps answering 200 because it
        # boots from the cached bootstrap/cache/config.php and never opens
        # .env — it only breaks on the next container restart or config:clear.
        EC="$REPOS_DIR/ecommerce"
        if [[ -d "$EC" ]]; then
            chown -R www-data:www-data "$EC/storage" "$EC/bootstrap/cache" 2>/dev/null || true
            if [[ -f "$EC/.env" ]]; then
                chown "$DEPLOY:www-data" "$EC/.env" 2>/dev/null || true
                chmod 640 "$EC/.env"
            fi
            ok "ecommerce storage/ + bootstrap/cache/ -> www-data; .env -> $DEPLOY:www-data 0640"
        fi

        # The OJS container runs as uid 33 and writes here.
        if [[ -d /var/www/biadenrekacipta ]]; then
            chown -R www-data:www-data "$OJS_DIR" "$OJS_FILES" 2>/dev/null || true
            chmod 750 "$OJS_FILES"
            ok "$OJS_DIR + $OJS_FILES -> www-data (uid 33)"

            # config.inc.php holds the db password: group-readable by www-data,
            # NOT world-readable. Mode 600 silently blanks the whole site.
            chown "$DEPLOY:www-data" "$OJS_DIR/config.inc.php" 2>/dev/null || true
            chmod 640 "$OJS_DIR/config.inc.php" 2>/dev/null || true
            find "$OJS_DIR" -maxdepth 1 -name 'config*.inc.php' -exec chown "$DEPLOY:www-data" {} \; 2>/dev/null || true
            ok "config.inc.php -> $DEPLOY:www-data 0640"
        fi

        chmod 700 /root/.hermes 2>/dev/null || true
        chmod 600 /root/.hermes/.env /root/.hermes/auth.json 2>/dev/null || true
        chown -R root:root /root/.hermes 2>/dev/null || true
        ok "/root/.hermes -> root (0700, secrets 0600)"

        for f in "$ROOT/vps.conf" "$ROOT/stack/stack.env" "$ROOT"/stack/apps/*.env; do
            [[ -f "$f" ]] && chmod 600 "$f"
        done
        ok "vps.conf + stack env files -> 0600"

        # A root-owned file in the deploy user's .git makes every later
        # `sudo -u <deploy> git` fail with a confusing permission error.
        if [[ "$(find "$SRV" -path '*/.git/*' -user root 2>/dev/null | wc -l)" -gt 0 ]]; then
            warn "$(find "$SRV" -path '*/.git/*' -user root 2>/dev/null | wc -l) root-owned files inside .git dirs"
            find "$SRV" -path '*/.git/*' -user root -exec chown "$DEPLOY:$DEPLOY" {} + 2>/dev/null || true
            ok "re-chowned .git trees to $DEPLOY"
        fi
    else
        warn "user '$DEPLOY' missing — skipped (run bootstrap.sh 00-base first)"
    fi
fi

# --- 5. verify --------------------------------------------------------------
if phase_enabled verify; then
    step "verify"
    rc=0
    check() { # check <label> <test...>
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then ok "$label"; else warn "NOT OK: $label"; rc=1; fi
    }

    check "deploy user exists"            getent passwd "$DEPLOY"
    check "$SRV populated"                test -d "$SRV/repos"
    check "$SRV/vps-plus present"         test -f "$ROOT/vps.conf"
    check "stack/stack.env present"       test -f "$ROOT/stack/stack.env"
    check "app env files present"         test -f "$ROOT/stack/apps/plus.env"
    check "root hermes config present"    test -f /root/.hermes/config.yaml
    check "root hermes secrets 0600"      test "$(stat -c %a /root/.hermes/.env 2>/dev/null)" = 600
    check "gateway USER unit present"      test -f /root/.config/systemd/user/hermes-gateway.service
    check "gateway unit is WantedBy"       test -L /root/.config/systemd/user/default.target.wants/hermes-gateway.service
    check "linger enabled for root"        test -f /var/lib/systemd/linger/root
    check "hermes launcher present"        test -x /usr/local/bin/hermes
    check "hermes venv interpreter"        test -x /usr/local/lib/hermes-agent/venv/bin/python
    check "hermes_cli package present"     test -d /usr/local/lib/hermes-agent/hermes_cli
    check "gateway ExecStart target"       test -f /usr/local/lib/hermes-agent/hermes
    check "OJS config.inc.php present"    test -f "$OJS_DIR/config.inc.php"
    check "OJS uploads present"           test -d "$OJS_FILES/journals"
    check "OJS cache cleared"             bash -c '! ls /var/www/biadenrekacipta/ojs/cache/*.css >/dev/null 2>&1'
    check "TLS certs restored"            test -d /etc/letsencrypt/live
    check "nginx config present"          test -d /etc/nginx/sites-available
    check "AppArmor override present"     test -s /etc/apparmor.d/local/usr.sbin.mysqld
    check "mysql systemd override"        test -s /etc/systemd/system/mysql.service.d
    check "docker daemon.json"            test -s /etc/docker/daemon.json
    check "ufw active"                    bash -c 'ufw status | grep -q "Status: active"'
    check "ecommerce .env group www-data"  bash -c 'test "$(stat -c %G /srv/repos/ecommerce/.env 2>/dev/null)" = www-data'
    check "ecommerce storage www-data"     bash -c 'test "$(stat -c %U /srv/repos/ecommerce/storage 2>/dev/null)" = www-data'
    check "postgres container running"    bash -c 'docker ps --format "{{.Names}}" | grep -qx vpsplus-postgres'
    check "mysql reachable"               mysqladmin ping

    if (( ! DRY_RUN )); then
        n=$(docker exec vpsplus-postgres psql -U "$PG_USER" -d plusthesite -tAc \
            "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null || echo 0)
        [[ "$n" -gt 0 ]] && ok "plusthesite public tables: $n" || { warn "plusthesite looks empty"; rc=1; }

        m=$(mysql -N -e "select count(*) from information_schema.tables where table_schema='ojs_local'" 2>/dev/null || echo 0)
        [[ "$m" -gt 0 ]] && ok "ojs_local tables: $m" || { warn "ojs_local looks empty"; rc=1; }
    fi

    printf '\n'
    if (( rc == 0 )); then ok "all checks passed"; else warn "some checks failed — see above"; fi
fi

# --- next steps -------------------------------------------------------------
printf '\n'
step "what is left (this script does not do it)"
cat <<EOF
  * build + start the containers:
        cd $ROOT && ./bootstrap.sh 70-apps 80-nginx 90-tls
  * OJS is NOT in APP_KEYS — start it explicitly:
        docker compose -f $ROOT/stack/ojs/docker-compose.yml up -d --build
        systemctl start mysql ojs-queue ojs-scheduler
  * supabase mini-stack:
        docker compose -f $ROOT/apps/supabase.compose.yml --env-file $ROOT/apps/supabase/supabase.env up -d
  * plus-office — a LOCAL BUILD (plus-office:latest is on no registry):
        docker compose -f /srv/plus-office/docker-compose.office.yml up -d --build
  * hermes gateway — ENABLED as a systemd --user unit, starts on boot. Do NOT
    start it before the OLD box's gateway is stopped; the exact command is in
    docs/MIGRATION.md, Phase 4 step 2
  * computer-use tooling (~/.cua-driver, 49 MB) is deliberately NOT in the
    bundle — reinstall it with 'hermes computer-use doctor' if you use it
  * then: docs/MIGRATION.md, "cutover" section (DNS, TLS, smoke test)

  Full bundle manifest : $BUNDLE/meta/machine.txt
  Cross-check ports     : $BUNDLE/meta/ports.txt
  Cross-check packages  : $BUNDLE/meta/dpkg-selections.txt
EOF
printf '\n'
warn "Shred the bundle on BOTH boxes once the migration is signed off: shred -u -r $BUNDLE"
