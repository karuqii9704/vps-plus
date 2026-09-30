#!/usr/bin/env bash
# migrate-golive.sh — one command on the NEW box: bundle -> live.
#
#   ops/migrate-golive.sh ~/migrate-bundle [--yes] [--skip-bootstrap]
#
# Everything the bundle already carries (SQL dumps, nginx vhosts, TLS certs,
# systemd units, AppArmor overrides, cron) is restored and started here. What
# this deliberately does NOT do, because it cannot be automatic:
#
#   * point DNS at this box — that is the cutover decision
#   * start the Hermes gateway — one bot token is one poller, and the old box
#     must stop first or Telegram messages are silently lost
#   * computer-use tooling (~/.cua-driver, 49 MB) — reinstall with
#     `hermes computer-use doctor` if you use it
#
# Everything else, including the fiddly parts (MySQL datadir, dpkg conffile
# prompts, production branches, the two stacks bootstrap does not know about),
# is handled so the box comes up serving the same thing the old one served.
set -uo pipefail
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'
ok(){   printf '  %sok%s   %s\n'   "$GREEN"  "$OFF" "$*"; }
bad(){  printf '  %sfail%s %s\n'   "$RED"    "$OFF" "$*"; FAIL=$((FAIL+1)); }
note(){ printf '  %snb%s   %s\n'   "$YELLOW" "$OFF" "$*"; }
step(){ printf '\n%s==>%s %s%s%s\n' "$BOLD" "$OFF" "$BOLD" "$*" "$OFF"; }
FAIL=0

BUNDLE="${1:-}"; shift || true
ASSUME_YES=0; SKIP_BOOTSTRAP=0
for a in "$@"; do
    [[ "$a" == "--yes" ]] && ASSUME_YES=1
    [[ "$a" == "--skip-bootstrap" ]] && SKIP_BOOTSTRAP=1
done

[[ -n "$BUNDLE" && -d "$BUNDLE/archives" ]] || { bad "usage: migrate-golive.sh <bundle-dir> [--yes]"; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { bad "jalankan sebagai root (sudo)"; exit 2; }
BUNDLE="$(cd "$BUNDLE" && pwd)"
REPO=/srv/vps-plus
source "$REPO/vps.conf" 2>/dev/null || true
DEPLOY_USER="${DEPLOY_USER:-plus}"

# --------------------------------------------------------------- 0. integrity
step "0. bundle utuh?"
( cd "$BUNDLE" && sha256sum -c --quiet checksums.sha256 ) \
    && ok "checksum cocok" \
    || { bad "checksum TIDAK cocok — jangan lanjut"; exit 1; }

# ------------------------------------------------------------------ 1. apt
step "1. apt: jangan pernah tanya soal config yang sudah ada dari bundle"
# The bundle overlays /etc before packages are installed, so every install would
# otherwise stop at a conffile prompt. These options make the bundle's file win,
# which is what we want: it is the config the old box was running.
cat > /etc/apt/apt.conf.d/99vps-plus-keep-bundle-config <<'EOF'
// Installed by migrate-golive.sh. The bundle restores /etc first, so packages
// must never replace that config with the maintainer's default.
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
EOF
ok "apt.conf.d/99vps-plus-keep-bundle-config ditulis"
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------- 2. bootstrap
if (( SKIP_BOOTSTRAP )); then
    note "bootstrap dilewati (--skip-bootstrap)"
else
    step "2. bootstrap runtime (base, docker, node)"
    ( cd "$REPO" && ./bootstrap.sh 00-base 10-docker 20-node 2>&1 | tail -6 )
    ok "runtime dasar siap"
fi

# ------------------------------------------- 3. stack yang tak dikenal bootstrap
step "3. MySQL untuk OJS (bootstrap tidak tahu soal ini)"
if ! command -v mysqld >/dev/null 2>&1; then
    apt-get update -qq
    apt-get -y -qq install mysql-server 2>&1 | tail -3
fi
ok "mysql-server: $(mysqld --version 2>/dev/null | head -1)"

DD=/var/lib/mysql-ojs
if [[ -s "$DD/ibdata1" ]]; then
    note "datadir $DD sudah ada"
else
    apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true
    install -d -o mysql -g mysql -m 750 "$DD"
    mysqld --initialize-insecure --user=mysql --datadir="$DD" >/dev/null 2>&1
    [[ -s "$DD/ibdata1" ]] && ok "datadir $DD diinisialisasi" || bad "init datadir gagal"
fi
systemctl reset-failed mysql 2>/dev/null || true
systemctl enable --now mysql >/dev/null 2>&1
sleep 4
mysqladmin ping >/dev/null 2>&1 && ok "mysqld hidup" || { bad "mysqld tidak hidup"; journalctl -u mysql -n 12 --no-pager | sed 's/^/      /'; }

# --------------------------------------------------- 4. import: files, system
step "4. restore files + system (termasuk vhost, TLS, unit, AppArmor)"
"$REPO/ops/migrate-import.sh" "$BUNDLE" --only files,system --yes 2>&1 | tail -12

step "5. postgres"
( cd "$REPO" && ./bootstrap.sh 60-postgres 2>&1 | tail -5 )

step "6. restore semua database (4 Postgres + MySQL OJS)"
"$REPO/ops/migrate-import.sh" "$BUNDLE" --only db --yes 2>&1 | tail -14

# -------------------------------------------------- 7. checkout ke branch prod
step "7. checkout ke branch PRODUKSI (bukan branch kerja agent)"
for spec in "plus|/srv/repos/plusthesite-|${BRANCH_PLUS:-main}" \
            "studio|/srv/repos/studio-plusthesite|${BRANCH_STUDIO:-main}" \
            "trilux|/srv/repos/trilux-design-page|${BRANCH_TRILUX:-master}" \
            "nalar|/srv/repos/new-nalar|${BRANCH_NALAR:-main}"; do
    key="${spec%%|*}"; rest="${spec#*|}"; dir="${rest%%|*}"; br="${rest#*|}"
    [[ -d "$dir/.git" ]] || { note "$key: tidak ada checkout"; continue; }
    cur=$(sudo -u "$DEPLOY_USER" git -C "$dir" branch --show-current 2>/dev/null)
    if [[ "$cur" != "$br" ]] && [[ -z "$(sudo -u "$DEPLOY_USER" git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
        sudo -u "$DEPLOY_USER" git -C "$dir" checkout "$br" >/dev/null 2>&1
    fi
    printf '  %-8s %s -> %s\n' "$key" "$br" \
        "$(sudo -u "$DEPLOY_USER" git -C "$dir" log -1 --format='%h %s' 2>/dev/null | cut -c1-52)"
done

# ------------------------------------------------------------ 8. apps + nginx
step "8. build + start aplikasi, nginx, TLS"
( cd "$REPO" && ./bootstrap.sh 70-apps 80-nginx 90-tls 2>&1 | tail -12 )

step "9. ownership + verifikasi akhir import"
"$REPO/ops/migrate-import.sh" "$BUNDLE" --only ownership,verify --yes 2>&1 | tail -14

# ------------------------------------------------ 10. yang tidak ada di APP_KEYS
step "10. nyalakan yang bootstrap tidak tahu"
# OJS: its own compose project, not in APP_KEYS.
if [[ -f "$REPO/stack/ojs/docker-compose.yml" ]]; then
    ( cd "$REPO" && docker compose -f stack/ojs/docker-compose.yml up -d --build 2>&1 | tail -6 )
    systemctl enable --now ojs-queue ojs-scheduler >/dev/null 2>&1
    ok "OJS: $(docker ps --filter name=vpsplus-ojs --format '{{.Names}}' | tr '\n' ' ')"
fi

# supabase: MUST be merged with the main stack. apps/supabase.compose.yml
# declares `depends_on: postgres`, and postgres is defined in
# stack/docker-compose.yml behind the `db` profile — run supabase's file alone
# and compose refuses with "depends on undefined service postgres". The
# containers on the old box carry both config_files for exactly this reason.
if [[ -f "$REPO/apps/supabase.compose.yml" ]]; then
    docker compose -f "$REPO/stack/docker-compose.yml" \
                   -f "$REPO/apps/supabase.compose.yml" \
                   --env-file "$REPO/apps/supabase/supabase.env" \
                   --profile db up -d 2>&1 | tail -8

    # pg_dump never carries role passwords, and apps/supabase/roles.sql creates
    # the roles bare. Without this, PostgREST and GoTrue crash-loop with
    # "password authentication failed for user authenticator". The passwords the
    # stack expects are inline in supabase.compose.yml, which travels in the
    # bundle — so read them from there and align the roles. Passwords are never
    # printed.
    align_role() { # <role> <password>
        docker exec vpsplus-postgres psql -U vpsplus -d postgres -q \
            -c "ALTER ROLE \"$1\" WITH LOGIN PASSWORD '$2';" >/dev/null 2>&1 \
            && ok "role $1: password diselaraskan" || bad "role $1: gagal diselaraskan"
    }
    supabase_uri_pw() { # <ENVVAR> -> user password
        grep -oE "$1: *postgres://[^ ]+" "$REPO/apps/supabase.compose.yml" | head -1 \
            | sed -E 's#.*://([^:]+):([^@]+)@.*#\1 \2#'
    }
    if docker inspect vpsplus-postgres >/dev/null 2>&1; then
        while read -r u p; do
            [[ -n "$u" && -n "$p" ]] && align_role "$u" "$p"
        done < <(
            for v in PGRST_DB_URI GOTRUE_DB_DATABASE_URL DATABASE_URL; do
                supabase_uri_pw "$v"; echo
            done
        )
        docker restart vpsplus-supabase-rest vpsplus-supabase-auth vpsplus-supabase-storage >/dev/null 2>&1 || true
        sleep 6
    fi
    ok "supabase: $(docker ps --filter name=vpsplus-supabase --format '{{.Names}}' | tr '\n' ' ')"
fi

# ecommerce is a bind-mount + FPM container inside stack/docker-compose.yml,
# behind the `ecommerce` profile. APP_KEYS does not list it, so bootstrap never
# starts it and nginx answers 502 on ecommerce.plusthe.site.
#
# NOTE the --env-file: compose does NOT read vps.conf. install/60-postgres.sh
# writes stack/stack.env and that is what supplies SRV_ROOT and REPOS_DIR. Run
# compose without it and the build context resolves to "/stack/ecommerce"
# (SRV_ROOT empty) and the build fails with "path not found".
if grep -q "profiles: \[ecommerce\]" "$REPO/stack/docker-compose.yml" 2>/dev/null; then
    if [[ -f "$REPO/stack/stack.env" ]]; then
        ( cd "$REPO" && docker compose --env-file stack/stack.env \
              -f stack/docker-compose.yml --profile ecommerce up -d --build 2>&1 | tail -6 )
        ok "ecommerce: $(docker ps --filter name=vpsplus-ecommerce --format '{{.Names}}' | tr '\n' ' ')"
    else
        bad "stack/stack.env tidak ada — jalankan bootstrap 60-postgres dulu"
    fi
fi

# plus-office: a LOCAL build. plus-office:latest is on no registry.
if [[ -f /srv/plus-office/docker-compose.office.yml ]]; then
    docker compose -f /srv/plus-office/docker-compose.office.yml up -d --build 2>&1 | tail -5
    ok "plus-office: $(docker ps --filter name=plusoffice --format '{{.Names}}' | tr '\n' ' ')"
fi
systemctl enable --now filebrowser >/dev/null 2>&1 || true

# OJS workers wait for the database; give them a nudge once everything is up.
for u in ojs-queue ojs-scheduler; do
    systemctl is-active --quiet "$u" || systemctl restart "$u" >/dev/null 2>&1 || true
done
ok "unit: mysql=$(systemctl is-active mysql) ojs-queue=$(systemctl is-active ojs-queue) ojs-scheduler=$(systemctl is-active ojs-scheduler) filebrowser=$(systemctl is-active filebrowser)"

# --------------------------------------------------------------- 11. smoke test
step "11. smoke test tiap domain (lewat loopback, DNS belum disentuh)"
for host in "${DOMAIN_PLUS:-}" "${DOMAIN_STUDIO:-}" "${DOMAIN_TRILUX:-}" \
            "${DOMAIN_ECOMMERCE:-}" office.plusthe.site testojs.plusthe.site; do
    [[ -z "$host" ]] && continue
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 12 \
           --resolve "$host:443:127.0.0.1" "https://$host/" 2>/dev/null)
    case "$code" in
        200|301|302|307|401|403) ok "$host -> $code" ;;
        000|"") bad "$host -> tidak menjawab" ;;
        *)      note "$host -> $code" ;;
    esac
done

# ------------------------------------------------------------------- 12. rekap
step "12. rekap"
printf '  container jalan : %s\n' "$(docker ps -q | wc -l)"
printf '  nginx           : %s\n' "$(systemctl is-active nginx)"
printf '  mysql           : %s\n' "$(systemctl is-active mysql)"
printf '  postgres        : %s\n' "$(docker inspect -f '{{.State.Status}}' vpsplus-postgres 2>/dev/null)"
echo
if (( FAIL > 0 )); then
    bad "$FAIL hal gagal — periksa di atas"
else
    ok "SEMUA HIJAU"
fi
cat <<'EOF'

  Yang SENGAJA tidak dilakukan script ini:
    1. DNS — arahkan A record ke IP box ini setelah kamu yakin.
       Cek dulu: ops/dns.sh --dry-run
    2. Gateway Hermes — satu bot token = satu poller. Matikan di box LAMA dulu,
       baru nyalakan di sini. Perintahnya di docs/MIGRATION.md Phase 4 langkah 2.
    3. Kalau selesai semua: shred bundle di KEDUA box.
         shred -u -r <bundle-dir>
EOF
exit $(( FAIL > 0 ))
