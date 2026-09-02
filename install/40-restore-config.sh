#!/usr/bin/env bash
# Unpacks the bundle produced by export/export-from-windows.ps1 into the deploy
# user's home, then rewrites the Windows paths baked into CLAUDE.md, AGENTS.md
# and the MCP config so the agents can actually find things on Linux.
#
# Restores are merges, not replacements: an existing ~/.claude/settings.json is
# backed up next to itself before being overwritten, so a bad bundle is never
# destructive.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${RESTORE_CONFIG:-1}" "restore-config" && exit 0

HOME_DIR="$(deploy_home)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# --- locate the bundle ------------------------------------------------------
BUNDLE="${BUNDLE:-}"
if [[ -z "$BUNDLE" ]]; then
    for cand in \
        "$HOME_DIR"/vps-plus-bundle.tar.gz.age \
        "$HOME_DIR"/vps-plus-bundle.tar.gz \
        /root/vps-plus-bundle.tar.gz.age \
        /root/vps-plus-bundle.tar.gz
    do
        if [[ -f "$cand" ]]; then BUNDLE="$cand"; break; fi
    done
fi

if [[ -z "$BUNDLE" ]]; then
    warn "no bundle found in $HOME_DIR or /root."
    warn "Run export/export-from-windows.ps1 on the Windows box, scp the result here,"
    warn "then: sudo BUNDLE=~/vps-plus-bundle.tar.gz.age $ROOT/bootstrap.sh --force 40"
    warn "Skipping — the agents will just prompt for login on first use."
    exit 0
fi
info "bundle: $BUNDLE"

WORK="$(mktemp -d)"
# The bundle is plaintext credentials once unpacked. Make sure a crash still
# leaves nothing readable behind.
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
chmod 700 "$WORK"

# --- decrypt + unpack -------------------------------------------------------
if [[ "$BUNDLE" == *.age ]]; then
    need_cmd age "installed by stage 00"
    info "decrypting (enter the passphrase you chose on Windows)"
    age --decrypt "$BUNDLE" > "$WORK/bundle.tar.gz" || die "age decryption failed"
    tar -xzf "$WORK/bundle.tar.gz" -C "$WORK"
    rm -f "$WORK/bundle.tar.gz"
else
    tar -xzf "$BUNDLE" -C "$WORK"
fi

[[ -f "$WORK/MANIFEST.json" ]] && log "exported $(jq -r .exported_at "$WORK/MANIFEST.json" 2>/dev/null) from $(jq -r .exported_from "$WORK/MANIFEST.json" 2>/dev/null)" || true

# place <src-in-bundle> <dest> — copies only if the source exists, backing up
# any file it would clobber.
place() {
    local src="$WORK/$1" dest="$2"
    [[ -e "$src" ]] || { log "absent in bundle: $1"; return 0; }
    install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$(dirname "$dest")"
    if [[ -e "$dest" && ! -d "$dest" ]]; then
        cp -a "$dest" "$dest.pre-restore-$STAMP"
    fi
    cp -a "$src" "$dest"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$dest"
    log "-> $dest"
}

# --- hermes -----------------------------------------------------------------
step_hermes() {
    local h="$HOME_DIR/.hermes"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$h"
    for f in .env config.yaml auth.json AGENTS.md SOUL.md channel_directory.json install_id; do
        place "hermes/$f" "$h/$f"
    done
    for d in memories cron hooks plugins skills platforms; do
        place "hermes/$d" "$h/$d"
    done
    # Gateway state: keeps the Discord bot from re-registering its slash
    # commands on first run. The credentials themselves are in .env.
    place hermes/gateway/discord_command_sync_state.json \
        "$h/gateway/discord_command_sync_state.json"

    place hermes/state.db    "$h/state.db"
    place hermes/kanban.db   "$h/kanban.db"
    place hermes/projects.db "$h/projects.db"

    # .env and auth.json are the crown jewels; nothing but the owner reads them.
    chmod 600 "$h/.env" "$h/auth.json" 2>/dev/null || true

    # Report what actually landed, so a half-empty bundle is visible now rather
    # than the first time Hermes cannot find a key.
    local nkeys nskills
    nkeys="$(grep -cE '^[A-Z_0-9]+=' "$h/.env" 2>/dev/null || echo 0)"
    nskills="$(find "$h/skills" -maxdepth 1 -mindepth 1 -type d -not -name '.*' 2>/dev/null | wc -l)"
    ok "hermes restored to $h — ${nkeys} env keys, ${nskills} skills"
}

# --- claude code ------------------------------------------------------------
step_claude() {
    local c="$HOME_DIR/.claude"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$c"
    for f in CLAUDE.md RTK.md settings.json settings.local.json .credentials.json keybindings.json; do
        place "claude/$f" "$c/$f"
    done
    for d in commands agents skills; do
        place "claude/$d" "$c/$d"
    done
    place claude/dot-claude.json "$HOME_DIR/.claude.json"
    chmod 600 "$c/.credentials.json" 2>/dev/null || true
    ok "claude code config restored to $c"
}

# --- gemini / codex ---------------------------------------------------------
step_gemini() {
    local g="$HOME_DIR/.gemini"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$g"
    for f in GEMINI.md settings.json oauth_creds.json; do place "gemini/$f" "$g/$f"; done
    for d in config instructions skills;              do place "gemini/$d" "$g/$d"; done
    chmod 600 "$g/oauth_creds.json" 2>/dev/null || true
    ok "gemini config restored"
}

step_codex() {
    local x="$HOME_DIR/.codex"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$x"
    for f in config.toml auth.json AGENTS.md; do place "codex/$f" "$x/$f"; done
    chmod 600 "$x/auth.json" 2>/dev/null || true
    ok "codex config restored"
}

# --- skills vault -----------------------------------------------------------
# Everything in your CLAUDE.md points at F:\Claude Work\PROJECTS\AI-Agent-Skills-Vault.
# On the VPS that becomes /srv/skills-vault, and the two agents get symlinks so
# neither needs a second copy.
step_vault() {
    local v="/srv/skills-vault"
    if [[ -d "$WORK/skills-vault" ]]; then
        install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$v"
        rsync -a --delete "$WORK/skills-vault/" "$v/"
        chown -R "$DEPLOY_USER:$DEPLOY_USER" "$v"
        ok "skills vault -> $v"
    elif [[ -d "$v" ]]; then
        log "vault already at $v (not in this bundle)"
    else
        warn "no skills vault in the bundle; Tier 0 skills will be unavailable"
        return 0
    fi

    if [[ -d "$v/Skills/Active" ]]; then
        # ln fails outright if the parent is missing, and a bundle without a
        # skills/ directory is perfectly normal — this stage must not abort
        # half way through, having already written credentials to disk.
        install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
            "$HOME_DIR/.hermes/skills" "$HOME_DIR/.claude/skills"
        ln -sfn "$v/Skills/Active" "$HOME_DIR/.hermes/skills/shared-vault"
        ln -sfn "$v/Skills/Active" "$HOME_DIR/.claude/skills/shared-vault"
        chown -h "$DEPLOY_USER:$DEPLOY_USER" \
            "$HOME_DIR/.hermes/skills/shared-vault" \
            "$HOME_DIR/.claude/skills/shared-vault" 2>/dev/null || true
        ok "shared-vault symlinks wired for hermes + claude"
    fi
}

# --- path rewriting ---------------------------------------------------------
# CLAUDE.md, AGENTS.md and friends hard-code Windows drive paths. Left alone,
# every Tier 0 skill lookup on the VPS fails silently.
step_rewrite() {
    local files=(
        "$HOME_DIR/.claude/CLAUDE.md"
        "$HOME_DIR/.claude/RTK.md"
        "$HOME_DIR/.hermes/AGENTS.md"
        "$HOME_DIR/.hermes/SOUL.md"
        "$HOME_DIR/.codex/AGENTS.md"
        "$HOME_DIR/.gemini/GEMINI.md"
    )
    local n=0
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        cp -a "$f" "$f.windows-$STAMP"
        # Longest paths first, so the vault rewrite is not eaten by the F:\ one.
        # The last rule needs the bracket class: GNU sed parses `s|\\|/|g` as
        # an alternation operator eating the delimiter, and aborts with
        # "unterminated `s' command". Do not "simplify" it back.
        sed -i \
            -e 's|F:\\Claude Work\\PROJECTS\\AI-Agent-Skills-Vault|/srv/skills-vault|g' \
            -e 's|F:/Claude Work/PROJECTS/AI-Agent-Skills-Vault|/srv/skills-vault|g' \
            -e "s|C:\\\\Users\\\\[A-Za-z0-9._-]*|$HOME_DIR|g" \
            -e "s|C:/Users/[A-Za-z0-9._-]*|$HOME_DIR|g" \
            -e 's|F:\\CLAUDE|/srv/claude-work|g' \
            -e 's|F:\\Claude Work\\PROJECTS|/srv/projects|g' \
            -e 's|E:\\PLUSSSSS|'"$REPOS_DIR"'|g' \
            -e 's|F:\\Trilux Design|'"$REPOS_DIR"'/trilux-design-page|g' \
            -e 's|F:\\NEW NALAR|'"$REPOS_DIR"'/new-nalar|g' \
            -e 's|[\\]|/|g' \
            "$f"
        chown "$DEPLOY_USER:$DEPLOY_USER" "$f"
        n=$((n+1))
    done
    ok "rewrote Windows paths in $n file(s); originals kept as *.windows-$STAMP"

    # config.yaml gets targeted edits only. The blanket backslash-to-slash rule
    # above is safe in prose but not in YAML, where a backslash can be a string
    # escape or part of a regex — converting those silently changes behaviour.
    local cfg="$HOME_DIR/.hermes/config.yaml"
    if [[ -f "$cfg" ]] && grep -qE '^[[:space:]]*cwd:[[:space:]]*[A-Za-z]:' "$cfg"; then
        cp -a "$cfg" "$cfg.windows-$STAMP"
        # terminal.cwd is where Hermes runs shell commands. On Windows it was a
        # projects drive that does not exist here; the repos are the closest
        # equivalent on the VPS.
        sed -i -E "s|^([[:space:]]*cwd:[[:space:]]*)[A-Za-z]:[^[:space:]]*|\1${REPOS_DIR}|" "$cfg"
        chown "$DEPLOY_USER:$DEPLOY_USER" "$cfg"
        ok "config.yaml: terminal.cwd -> $REPOS_DIR"
    fi

    # Anything else with a drive letter in it is reported, not guessed at. The
    # leading (^|[^A-Za-z]) matters: a bare [A-Za-z]:[\\/] also matches every
    # https:// and docker:// in the file, and a warning that always fires is a
    # warning nobody reads.
    local drive_re='(^|[^A-Za-z])[A-Za-z]:[\\/]'
    if [[ -f "$cfg" ]] && grep -qE "$drive_re" "$cfg"; then
        warn "config.yaml still mentions Windows paths:"
        grep -nE "$drive_re" "$cfg" | head -5 | sed 's/^/      /'
    fi

    # Same problem in the MCP config: local stdio servers reference Windows
    # paths that do not exist here. Flag rather than guess.
    if [[ -f "$HOME_DIR/.claude.json" ]] && grep -qE '[A-Z]:\\\\' "$HOME_DIR/.claude.json"; then
        warn "~/.claude.json still contains Windows paths (MCP server definitions)."
        warn "Review it: grep -o '[A-Z]:[^\"]*' ~/.claude.json | sort -u"
    fi
}

# --- application env --------------------------------------------------------
# App secrets go to stack/apps/, which docker compose reads with env_file.
# They never enter the image and never enter git.
step_appenv() {
    local d="$ROOT/stack/apps"
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$d"
    local found=0
    for a in plus studio trilux nalar; do
        if [[ -f "$WORK/appenv/$a.env" ]]; then
            install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
                "$WORK/appenv/$a.env" "$d/$a.env"
            log "-> stack/apps/$a.env"
            found=$((found+1))
        fi
    done
    if [[ $found -gt 0 ]]; then
        ok "$found application env file(s) restored"
    else
        warn "no app env files in the bundle — copy stack/apps/*.env.example and fill them in"
    fi
}

step_hermes
step_claude
step_gemini
step_codex
step_vault
step_rewrite
step_appenv

# --- gateway: one poller only ------------------------------------------------
# The restored .env carries live Telegram and Discord bot tokens. Both bots are
# currently connected from the Windows machine, and a bot token is not
# something two processes can share: Telegram's getUpdates hands the long-poll
# to whoever asked last, so two gateways fight over every message and each one
# sees roughly half of them. Discord tolerates the second connection but then
# answers everything twice.
#
# Nothing here starts the gateway, precisely so this is your decision.
if grep -qE '^(TELEGRAM_BOT_TOKEN|DISCORD_BOT_TOKEN)=.+' "$HOME_DIR/.hermes/.env" 2>/dev/null; then
    printf '\n'
    warn "The Hermes gateway tokens were restored, but the gateway was NOT started."
    warn "Stop the gateway on Windows before starting it here — one bot token"
    warn "cannot be polled from two machines without messages going missing."
    warn ""
    warn "  windows :  close Hermes, or disable Hermes_Gateway.vbs at startup"
    warn "  vps     :  hermes gateway run     (then add a systemd unit to keep it up)"
fi

# --- destroy the bundle -----------------------------------------------------
info "shredding the bundle (it is plaintext credentials once decrypted)"
shred -u "$BUNDLE" 2>/dev/null || rm -f "$BUNDLE"
ok "bundle removed from the VPS"

warn "Delete the copy on your Windows machine too."
