#!/usr/bin/env bash
# migrate-audit.sh — find everything on this box that the migration path does
# NOT reproduce. Read-only; safe to run any time.
#
#   ops/migrate-audit.sh [bundle-dir]
#
# Run it BEFORE the final export. The whole point is that a migration's failure
# mode is omission, not breakage: the new box comes up green and something quiet
# is missing (a systemd --USER unit, a CLI in ~/.local, a client report in
# /root). This walks every container, unit, cron entry, port and home directory
# and says COVERED / NOTE / GAP for each.
#
# Exit status is 1 if any GAP remains, so it can gate a cutover.

set -uo pipefail
B="${1:-}"
if [[ -z "$B" ]]; then
    B="$(ls -1d /srv/data/migrate/bundle-* 2>/dev/null | tail -1)"
fi
[[ -n "$B" && -d "$B/archives" ]] || {
    echo "usage: migrate-audit.sh <bundle-dir>   (or run an export first)" >&2; exit 2
}
B="$(cd "$B" && pwd)"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'
step(){ printf '\n%s==>%s %s%s%s\n' "$BOLD" "$OFF" "$BOLD" "$*" "$OFF"; }
ok(){  printf '  %sCOVERED%s  %s\n' "$GREEN"  "$OFF" "$*"; }
gap(){ printf '  %sGAP%s      %s\n' "$RED"    "$OFF" "$*"; GAPS=$((GAPS+1)); }
nb(){  printf '  %sNOTE%s     %s\n' "$YELLOW" "$OFF" "$*"; }
GAPS=0

ROOT_H="${HOME:-/root}"
DEPLOY_USER="$(grep -m1 '^DEPLOY_USER=' /srv/vps-plus/vps.conf 2>/dev/null | cut -d= -f2- | cut -d' ' -f1)"
DEPLOY_USER="${DEPLOY_USER:-plus}"
DEPLOY_H="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"; DEPLOY_H="${DEPLOY_H:-/home/$DEPLOY_USER}"

# Where the checkouts live. REPO_ROOT is derived from this script's own location
# so nothing is hardcoded: ops/ -> repo root.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
REPOS_DIR="${REPOS_DIR:-/srv/repos}"

A_ROOT=$(mktemp); A_SRV=$(mktemp); A_ETC=$(mktemp); A_WWW=$(mktemp); A_OJSQA=$(mktemp)
for f in "$B"/archives/*.tar.zst; do
    n=$(basename "$f" .tar.zst)
    tar --zstd -tf "$f" 2>/dev/null > "/tmp/.audit-$n.list"
done
have() { grep -qE "^$2(/|\$)" "/tmp/.audit-$1.list" 2>/dev/null; }

step "container → jalur migrasinya"
for c in $(docker ps --format '{{.Names}}' | sort); do
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
    src=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
    if [[ -z "$src" ]]; then
        gap "$c ($img) — tidak diluncurkan oleh compose mana pun"
        continue
    fi
    missing=""
    for cf in ${src//,/ }; do [[ -f "$cf" ]] || missing="$cf"; done
    if [[ -n "$missing" ]]; then gap "$c — compose hilang: $missing"
    else ok "$c ($img) ← $src"; fi
done

step "image per container: dibangun lokal atau ditarik"
# RepoDigests cannot tell them apart (a BuildKit build with provenance gets a
# local manifest list, so built images carry a digest too). Read the compose
# files instead, and derive the name the way compose does: a service with
# `build:` and no `image:` is tagged <project>-<service> from the top-level
# `name:` key (stack/docker-compose.yml says `name: vpsplus`, so service `plus`
# becomes `vpsplus-plus`).
#
# Only RUNNING containers are judged. A compose file legitimately declares
# services that are not deployed (nalar has no domain) or live behind a profile
# (plus-office's local-llm → ollama), and calling those gaps is noise.
BUILTMAP=$(mktemp)
for f in /srv/vps-plus/stack/docker-compose.yml /srv/vps-plus/stack/ojs/docker-compose.yml \
         /srv/vps-plus/apps/supabase.compose.yml /srv/plus-office/docker-compose.office.yml; do
    [[ -f "$f" ]] || continue
    awk '
      function flush() { if (svc != "" && hb) print (img != "" ? img : proj "-" svc) }
      /^name:[[:space:]]*/ { proj = $0; sub(/^name:[[:space:]]*/, "", proj); sub(/[[:space:]]*$/, "", proj); next }
      /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
          flush(); svc = $0; sub(/^[[:space:]]+/, "", svc); sub(/:.*/, "", svc); hb = 0; img = ""; next
      }
      /^[[:space:]]+build:/ { hb = 1; next }
      /^[[:space:]]+image:/ {
          img = $0; sub(/^[[:space:]]+image:[[:space:]]*/, "", img); sub(/[[:space:]]*$/, "", img); next
      }
      END { flush() }
    ' "$f" >> "$BUILTMAP"
done
# resolve ${VAR:-default} / ${VAR} the way compose would
sed -i -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g; s/\$\{[A-Za-z_][A-Za-z0-9_]*\}/?/g' "$BUILTMAP"
sort -u "$BUILTMAP" -o "$BUILTMAP"

for c in $(docker ps --format '{{.Names}}' | sort); do
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
    if grep -qxF "$img" "$BUILTMAP"; then
        printf '  %sCOVERED%s %-30s BUILD lokal (compose punya blok build:)\n' "$GREEN" "$OFF" "$img"
        continue
    fi
    # Not built by compose. It must therefore be pullable. A name with no
    # registry namespace and no official-image pedigree is a hand-made local tag
    # — exactly the `vpsplus-ojs:tools` bug: nothing created it, it only existed
    # because someone ran `docker tag` once, and on a fresh box compose would try
    # to pull it from Docker Hub and fail, leaving the service dead.
    repo="${img%%:*}"
    if [[ "$repo" == */* ]] || [[ "$repo" =~ ^(postgres|mysql|nginx|node|php|redis|alpine|busybox|composer|mariadb|mongo|rabbitmq|memcached|traefik|wordpress|python|debian|ubuntu)$ ]]; then
        printf '  %sCOVERED%s %-30s %sditarik dari registry%s\n' "$GREEN" "$OFF" "$img" "$DIM" "$OFF"
    else
        gap "$c pakai '$img' — bukan hasil build compose, bukan image registry yang jelas"
        echo "           → compose akan mencoba PULL dan gagal di box baru. Cek: docker tag / build.tags"
    fi
done

echo "  ${DIM}compose mendeklarasikan build: untuk image ini, tapi tidak ada container yang jalan (belum di-deploy / di balik profile) — bukan gap:${OFF}"
while read -r img; do
    [[ -n "$img" && "$img" != "?" ]] || continue
    docker ps --format '{{.Image}}' | grep -qxF "$img" && continue
    printf '    %s\n' "$img"
done < "$BUILTMAP"
rm -f "$BUILTMAP"

step "/usr/local — instal manual di luar paket"
for d in /usr/local/bin /usr/local/lib/*/; do
    [[ -e "$d" ]] || continue
    n="$(basename "${d%/}")"
    if [[ "$n" == bin ]]; then
        # NOTE the slash: "${d%/}"/* not "$d"* — without it the glob also
        # matches the directory itself and reports "usr/local/bin/bin".
        for f in "${d%/}"/*; do
            [[ -e "$f" ]] || continue
            b="usr/local/bin/$(basename "$f")"
            if have usr-local "$b"; then ok "$b"
            elif dpkg -S "$f" >/dev/null 2>&1; then :
            elif [[ "$(readlink -f "$f" 2>/dev/null)" == /usr/local/qcloud/* ]]; then
                nb "$b — symlink ke agen cloud provider (/usr/local/qcloud), dipasang image"
            else gap "$b ($(du -h "$f" 2>/dev/null | cut -f1)) — tidak di bundle"; fi
        done
    else
        if have usr-local "usr/local/lib/$n"; then ok "usr/local/lib/$n ($(du -sh "$d" | cut -f1))"
        else
            sz=$(du -sh "$d" 2>/dev/null | cut -f1)
            [[ "$sz" == "8.0K" || "$sz" == "4.0K" ]] && nb "usr/local/lib/$n ($sz) — kosong, abaikan" \
                || gap "usr/local/lib/$n ($sz) — tidak di bundle"
        fi
    fi
done

step "unit systemd custom: ExecStart-nya benar-benar ada?"
for u in $(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}'); do
    p=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
    case "$p" in /etc/systemd/system/*) ;; *) continue ;; esac
    bin=$(systemctl show -p ExecStart --value "$u" 2>/dev/null | grep -oE '/[^ ;]+' | head -1)
    [[ -n "$bin" ]] || continue
    if [[ -x "$bin" ]]; then ok "$u → $bin"
    else gap "$u → $bin TIDAK ADA di box ini"; fi
done

step "checkout: ada kerja yang HANYA ada di box ini?"
# A commit that exists only on the old box is what a migration loses. This is
# the single highest-value check here: when it was written on 2026-09-28 it
# found 13 unpushed commits in trilux-design-page, 11 in ecommerce, 4 unpushed
# branches in plusthesite- and 2 in studio-plusthesite. Nothing else in this
# audit would have caught any of it, and all of it would have died with the box.
for r in "${REPOS_DIR}"/* "$REPO_ROOT" "$DEPLOY_H/bec-repo"; do
    [[ -d "$r/.git" ]] || continue
    name=$(basename "$r")
    problems=""

    dirty=$(sudo -u "$DEPLOY_USER" git -C "$r" status --porcelain 2>/dev/null | wc -l)
    [[ "$dirty" -gt 0 ]] && problems="$problems\n           $dirty path belum di-commit"
    notes=""

    sudo -u "$DEPLOY_USER" git -C "$r" fetch --quiet --all 2>/dev/null || true
    remotes=$(sudo -u "$DEPLOY_USER" git -C "$r" remote 2>/dev/null)

    # Ahead of your OWN upstream is not migration risk by itself: those commits
    # may already live on the remote under another name. trilux-design-page's
    # master is 10 ahead of origin/master, yet every one of them is also on
    # origin/backup/master-2026-09-26. The reachability loop below is the real
    # gate, so this is a NOTE -- as a GAP it called safe work lost and
    # contradicted that loop.
    br=$(sudo -u "$DEPLOY_USER" git -C "$r" branch --show-current 2>/dev/null)
    if [[ -n "$br" ]]; then
        up=$(sudo -u "$DEPLOY_USER" git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
        if [[ -n "$up" ]]; then
            ahead=$(sudo -u "$DEPLOY_USER" git -C "$r" rev-list --count "$up..$br" 2>/dev/null || echo 0)
            [[ "${ahead:-0}" -gt 0 ]] && notes="$notes\n           branch '$br' $ahead commit di depan $up -- cek reachability di bawah"
        fi
    fi

    # A branch is safe if its tip commit is reachable from ANY remote-tracking
    # ref. Two traps this avoids: a stale local `master` whose commits already
    # live on the remote under `agent/...`, and work pushed to a mirror because
    # the upstream is read-only. Comparing branch NAMES gets both wrong.
    unp=""
    for b in $(sudo -u "$DEPLOY_USER" git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null); do
        tip=$(sudo -u "$DEPLOY_USER" git -C "$r" rev-parse "$b" 2>/dev/null)
        sudo -u "$DEPLOY_USER" git -C "$r" branch -r --contains "$tip" 2>/dev/null | grep -q . \
            || unp="$unp $b"
    done
    [[ -n "$unp" ]] && problems="$problems\n           commit tidak ada di remote mana pun:$unp"

    if [[ -n "$problems" ]]; then
        gap "$name — $(printf "$problems" | grep -c '^') temuan di atas"
        printf "$problems\n" | grep .
    else
        ok "$name — bersih & semua branch ada di remote"
    fi
    [[ -n "$notes" ]] && printf "$notes\n" | grep . | while IFS= read -r l; do
        nb "$(sed 's/^ *//' <<<"$l")"
    done
done
echo "  ${DIM}kalau kamu tidak punya hak push ke sebuah repo, kerja tetap bisa diselamatkan:${OFF}"
echo "  ${DIM}  sudo -u $DEPLOY_USER git -C <repo> bundle create /tmp/<repo>.bundle --all${OFF}"
echo "  ${DIM}file .bundle itu bisa di-clone langsung, dan .git-nya juga sudah ikut di srv.tar.zst.${OFF}"

step "$ROOT_H — seluruh isi vs bundle"
for e in $(ls -A "$ROOT_H" 2>/dev/null); do
    if have hermes-root "$(basename "$ROOT_H")/$e"; then ok "$ROOT_H/$e"
    else
        case "$e" in
            .cache|.npm|.cua-driver) nb "$ROOT_H/$e ($(du -sh "$ROOT_H/$e" 2>/dev/null | cut -f1)) — rebuildable, sengaja di-exclude" ;;
            # Written by the Tencent image on first boot, minutes before the
            # restore: pip/npm/easy_install pointed at the regional mirrors.
            # They are provisioning, not migration content, so the bundle has
            # nothing to carry — and they are regenerated if the image is.
            .npmrc|.pip|.pydistutils.cfg)
                nb "$ROOT_H/$e — provisioning image (mirror Tencent), bukan isi migrasi" ;;
            *) gap "$ROOT_H/$e ($(du -sh "$ROOT_H/$e" 2>/dev/null | cut -f1))" ;;
        esac
    fi
done

step "systemd --USER unit (tak terlihat oleh systemctl biasa)"
for u in "$ROOT_H" "$DEPLOY_H"; do
    d="$u/.config/systemd/user"
    [[ -d "$d" ]] || { nb "$u: tidak ada unit user"; continue; }
    for f in $(ls -A "$d" 2>/dev/null); do
        if [[ "$u" == "$ROOT_H" ]] && have hermes-root "$(basename "$u")/.config/systemd/user/$f"; then
            ok "$u/.config/systemd/user/$f  (linger: $( [[ -f /var/lib/systemd/linger/$(basename "$u") ]] && echo yes || echo NO))"
        elif [[ "$u" == "$DEPLOY_H" ]] && have home-deploy "$(basename "$u")/.config/systemd/user/$f"; then
            ok "$u/.config/systemd/user/$f  (linger: $( [[ -f /var/lib/systemd/linger/$(basename "$u") ]] && echo yes || echo NO))"
        else
            gap "$u/.config/systemd/user/$f — tidak ikut bundle"
        fi
    done
done

step "service systemd aktif"
for s in $(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -v '\.mount'); do
    p=$(systemctl show -p FragmentPath --value "$s" 2>/dev/null)
    case "$p" in
        /etc/systemd/system/*)
            b="etc/systemd/system/$(basename "$p")"
            if have etc-system "$b"; then ok "$s (custom) — $p"
            elif systemctl show -p ExecStart --value "$s" 2>/dev/null | grep -q '/usr/local/qcloud/'; then
                nb "$s (custom) — $p — ExecStart di /usr/local/qcloud (agen provider), dipasang image"
            else gap "$s (custom) — $p TIDAK di bundle"; fi ;;
        "") nb "$s — tanpa FragmentPath (generated?)" ;;
        *)  : ;;   # paket: dipasang ulang oleh bootstrap
    esac
done
echo "  ${DIM}(service dari paket tidak dilaporkan — bootstrap memasangnya ulang)${OFF}"

step "cron"
crontab -l 2>/dev/null | grep -vE '^\s*#|^\s*$' | while read -r l; do echo "  root: $l"; done
[[ -f /var/spool/cron/crontabs/$DEPLOY_USER ]] && \
    sudo -u "$DEPLOY_USER" crontab -l 2>/dev/null | grep -vE '^\s*#|^\s*$' | while read -r l; do echo "  $DEPLOY_USER: $l"; done
if have etc-system "var/spool/cron/crontabs"; then ok "crontab dibawa di bundle"; else gap "crontab TIDAK di bundle"; fi

step "port yang listening (peta, bukan cek)"
ss -tulpnH 2>/dev/null | awk '{split($5,a,":"); p=a[length(a)]; if (p!="") print p}' | sort -un | tr '\n' ' ' | sed 's/^/  /'
echo

step "deliverable / berkas penting yang hanya ada di luar bundle"
find "$ROOT_H" -maxdepth 1 -type f 2>/dev/null | while read -r f; do
    if have hermes-root "$(basename "$ROOT_H")/$(basename "$f")"; then continue; fi
    b=$(basename "$f")
    case "$b" in
        .npmrc|.pydistutils.cfg)
            nb "$b — provisioning image (mirror Tencent), bukan isi migrasi"; continue ;;
    esac
    if find /srv "$DEPLOY_H" -name "$b" 2>/dev/null | grep -q .; then
        nb "$b — ada salinan lain"
    else
        gap "$b ($(du -h "$f" | cut -f1)) — HANYA di $ROOT_H"
    fi
done

printf '\n'
if [[ $GAPS -eq 0 ]]; then
    ok "AUDIT BERSIH — setiap hal di atas punya jalur migrasi"
else
    gap "$GAPS hal tanpa jalur migrasi — bereskan sebelum cutover"
fi
rm -f /tmp/.audit-*.list "$A_ROOT" "$A_SRV" "$A_ETC" "$A_WWW" "$A_OJSQA"
exit $(( GAPS > 0 ))
