#!/usr/bin/env bash
# migrate-go.sh — the "on your mark, get set, GO" button.
#
#   ops/migrate-go.sh <user@new-host>              push the bundle as it is
#   ops/migrate-go.sh <user@new-host> --freeze     freeze first, then push
#
# Without --freeze it only ships the bundle that is already built. With
# --freeze it stops the Hermes gateway and the HQ agent team, commits and
# pushes every checkout, rebuilds the bundle, gates it through the audit, and
# only then transfers. --freeze is the correct mode for the real cutover; plain
# mode is for pre-staging most of the bytes while the old box still serves.
#
# Nothing here points the DNS at anything. That stays a deliberate, separate
# step (docs/MIGRATION.md, Phase 4).
set -uo pipefail
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'
ok(){   printf '  %sok%s   %s\n'   "$GREEN"  "$OFF" "$*"; }
bad(){  printf '  %sfail%s %s\n'   "$RED"    "$OFF" "$*"; }
note(){ printf '  %snb%s   %s\n'   "$YELLOW" "$OFF" "$*"; }
step(){ printf '\n%s==>%s %s%s%s\n' "$BOLD" "$OFF" "$BOLD" "$*" "$OFF"; }

REPO=/srv/vps-plus
BUNDLE="${BUNDLE:-$(ls -1d /srv/data/migrate/bundle-* 2>/dev/null | tail -1)}"
DEPLOY_USER="$(grep -m1 '^DEPLOY_USER=' "$REPO/vps.conf" 2>/dev/null | cut -d= -f2- | cut -d' ' -f1)"; DEPLOY_USER="${DEPLOY_USER:-plus}"
DEPLOY_H="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"; DEPLOY_H="${DEPLOY_H:-/home/$DEPLOY_USER}"

TARGET="${1:-}"; shift || true
FREEZE=0
for a in "$@"; do
    [[ "$a" == "--freeze" ]] && FREEZE=1
done

[[ -n "$TARGET" ]] || { bad "usage: migrate-go.sh <user@new-host> [--freeze]"; exit 2; }
[[ -n "$BUNDLE" && -d "$BUNDLE/archives" ]] || { bad "no bundle found — run ops/migrate-export.sh first"; exit 2; }

# ---------------------------------------------------------------- preflight
step "preflight: $TARGET"
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$TARGET" true 2>/dev/null; then
    bad "tidak bisa SSH ke $TARGET tanpa password (BatchMode)"
    note "pastikan kunci publik $DEPLOY_USER sudah ada di authorized_keys box baru"
    note "atau jalankan transfer manual: $BUNDLE/transfer.sh $TARGET"
    exit 1
fi
ok "SSH tersambung"
REMOTE_OS=$(ssh -o BatchMode=yes "$TARGET" '. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"' 2>/dev/null)
ok "target: ${REMOTE_OS:-tidak diketahui}"
REMOTE_FREE=$(ssh -o BatchMode=yes "$TARGET" "df -BG --output=avail / | tail -1 | tr -dc '0-9'" 2>/dev/null)
if [[ -n "$REMOTE_FREE" ]]; then
    if [[ "$REMOTE_FREE" -lt 60 ]]; then
        bad "hanya ${REMOTE_FREE}G free di / box baru — import butuh ~50G"
    else
        ok "disk free: ${REMOTE_FREE}G"
    fi
fi
ssh -o BatchMode=yes "$TARGET" 'command -v rsync >/dev/null' 2>/dev/null \
    && ok "rsync ada di target" \
    || { bad "rsync tidak ada di target (apt-get install -y rsync)"; exit 1; }

# ------------------------------------------------------------------- freeze
if [[ $FREEZE -eq 1 ]]; then
    step "FREEZE: hentikan tim agent (gateway tetap hidup)"
    note "satu bot token = satu poller; dua-duanya jalan = pesan Telegram hilang"

    # The gateway is the operator's own Telegram channel. Stopping it from
    # inside the agent would silence the agent mid-migration (SIGTERM
    # propagates), so this script never issues that command at all — and the
    # tooling blocks it if it appears here. It belongs immediately before the
    # NEW box's gateway starts, which is after the import: the exact command is
    # in docs/MIGRATION.md, Phase 4 step 2. Run it yourself, from a shell that
    # is not the gateway.
    if systemctl --user is-active --quiet hermes-gateway 2>/dev/null; then
        note "gateway Hermes DIBIARKAN HIDUP (itu jalur bicara operator ke agent)"
        note "matikan dia nanti — lihat docs/MIGRATION.md Phase 4 langkah 2"
    else
        note "gateway Hermes tidak aktif"
    fi

    n=$(pgrep -f '/srv/hq/run-agent\.sh' 2>/dev/null | wc -l)
    if [[ "${n:-0}" -gt 0 ]]; then
        pkill -f '/srv/hq/run-agent.sh' 2>/dev/null
        sleep 3
        left=$(pgrep -f '/srv/hq/run-agent\.sh' 2>/dev/null | wc -l)
        [[ "${left:-0}" -eq 0 ]] && ok "$n proses agent dihentikan" || bad "$left proses agent masih hidup"
    else
        note "tidak ada proses agent"
    fi
    # kill-server takes the whole tmux server with it, which is what stops the
    # agent sessions; it exits non-zero when no server is running, which is not
    # a failure worth reporting as one.
    if sudo -u "$DEPLOY_USER" tmux has-session 2>/dev/null; then
        sudo -u "$DEPLOY_USER" tmux kill-server 2>/dev/null
        sudo -u "$DEPLOY_USER" tmux has-session 2>/dev/null \
            && bad "sesi tmux masih hidup" || ok "server tmux dihentikan (semua sesi agent ikut)"
    else
        note "tidak ada server tmux"
    fi

    step "commit + push setiap checkout (kerja yang hanya di box ini = hilang)"
    for r in /srv/repos/* "$REPO" "$DEPLOY_H/bec-repo"; do
        [[ -d "$r/.git" ]] || continue
        name=$(basename "$r")
        g() { sudo -u "$DEPLOY_USER" git -C "$r" "$@"; }

        if [[ -n "$(g status --porcelain 2>/dev/null)" ]]; then
            g add -A 2>/dev/null
            g commit -q -m "chore: freeze working tree before the VPS cutover" 2>/dev/null \
                && ok "$name — perubahan di-commit" || bad "$name — commit gagal"
        fi

        for b in $(g for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null); do
            tip=$(g rev-parse "$b" 2>/dev/null)

            # Already on SOME remote? Then nothing to push, whatever the branch
            # is called there. This is the case that matters: a stale local
            # `master` whose commits live on the remote as `agent/...`, or work
            # pushed to a mirror because the upstream is read-only.
            if g branch -r --contains "$tip" 2>/dev/null | grep -q .; then
                continue
            fi

            # Pick a remote that actually has this branch, else origin.
            target=origin
            for rem in $(g remote 2>/dev/null); do
                if g rev-parse --verify --quiet "$rem/$b" >/dev/null 2>&1; then target="$rem"; break; fi
            done

            out=$(g push -u "$target" "$b" 2>&1 | tail -1)
            case "$out" in
                *"Everything up-to-date"*|*"->"*|*"set up to track"*) ok "$name/$b -> $target" ;;
                *) bad "$name/$b -> $target — $out" ;;
            esac
        done
    done
    ok "selesai — cek GAP di audit di bawah"

    step "export ulang (box sudah beku, jadi bundle ini akurat)"
    "$REPO/ops/migrate-export.sh" --dest "$BUNDLE" --force > /tmp/migrate-go-export.log 2>&1 \
        && ok "export selesai: $(du -sh "$BUNDLE" | cut -f1)" \
        || { bad "export gagal — lihat /tmp/migrate-go-export.log"; exit 1; }

    step "AUDIT (gate)"
    "$REPO/ops/migrate-audit.sh" "$BUNDLE" > /tmp/migrate-go-audit.log 2>&1
    if [[ $? -eq 0 ]]; then
        ok "AUDIT BERSIH"
    else
        bad "audit masih ada GAP — baca /tmp/migrate-go-audit.log"
        sed 's/\x1b\[[0-9;]*m//g' /tmp/migrate-go-audit.log | grep -A3 'GAP' | head -20 | sed 's/^/      /'
        note "bisa lanjut, tapi ketahui apa yang belum tertutup"
    fi
fi

# ----------------------------------------------------------------- transfer
step "transfer $(du -sh "$BUNDLE" | cut -f1) -> $TARGET"
note "rsync inkremental: menjalankan ulang hanya mengirim yang berubah"
if rsync -az --info=stats2 -e ssh "$BUNDLE/" "$TARGET:~/migrate-bundle/"; then
    ok "transfer selesai"
else
    bad "rsync gagal"; exit 1
fi

step "verifikasi integritas DI box baru"
if ssh -o BatchMode=yes "$TARGET" 'cd ~/migrate-bundle && chmod -R go-rwx . && sha256sum -c --quiet checksums.sha256' 2>/dev/null; then
    ok "checksum cocok di box baru — bundle utuh"
else
    bad "checksum TIDAK cocok — ulangi transfer"
    exit 1
fi

step "langkah berikutnya — DI BOX BARU"
cat <<EOF
  # 1. bootstrap runtime (box baru belum punya docker/node/postgres)
  cd /srv/vps-plus
  ./bootstrap.sh 00-base 10-docker 20-node

  # 2. restore data + config, mengikuti urutan di RESTORE.md
  ./ops/migrate-import.sh ~/migrate-bundle --only files,system
  ./bootstrap.sh 60-postgres
  ./ops/migrate-import.sh ~/migrate-bundle --only db
  ./bootstrap.sh 70-apps 80-nginx 90-tls
  ./ops/migrate-import.sh ~/migrate-bundle --only ownership,verify

  # 3. nyalakan yang tidak dikenal bootstrap
  docker compose -f stack/ojs/docker-compose.yml up -d --build
  docker compose -f apps/supabase.compose.yml --env-file apps/supabase/supabase.env up -d
  docker compose -f /srv/plus-office/docker-compose.office.yml up -d --build

  # 4. gateway Hermes DI SINI baru boleh dinyalakan, setelah gateway box lama mati
  #    (lihat docs/MIGRATION.md Phase 4 langkah 2)
EOF
echo
ok "bundle siap di $TARGET:~/migrate-bundle"
note "DNS belum disentuh — itu langkah terpisah di Phase 4"
