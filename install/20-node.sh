#!/usr/bin/env bash
# Node 22 via nvm, installed into the deploy user's home rather than system
# wide. The AI CLIs are npm globals and updating them must never need sudo.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_NODE:-1}" "node" && exit 0

NODE_MAJOR=22
HOME_DIR="$(deploy_home)"

if [[ -d "$HOME_DIR/.nvm" ]]; then
    log "nvm already installed"
else
    info "installing nvm for $DEPLOY_USER"
    as_deploy 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash' >/dev/null
fi

info "node ${NODE_MAJOR}"
as_deploy "source \$HOME/.nvm/nvm.sh && nvm install ${NODE_MAJOR} && nvm alias default ${NODE_MAJOR}" >/dev/null
ok "$(as_deploy 'source $HOME/.nvm/nvm.sh && node --version') / npm $(as_deploy 'source $HOME/.nvm/nvm.sh && npm --version')"

# corepack gives pnpm and yarn without another global install; bun is a
# separate runtime the studio build can use.
as_deploy 'source $HOME/.nvm/nvm.sh && corepack enable' >/dev/null 2>&1 || warn "corepack enable failed"

if ! as_deploy 'command -v bun' >/dev/null 2>&1; then
    info "installing bun"
    as_deploy 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1 || warn "bun install failed (not fatal)"
fi

# nvm's own installer appends to .bashrc, but a non-interactive `ssh host cmd`
# bails out of .bashrc early. Putting it in .profile too makes `as_deploy` and
# any cron job see node.
if ! grep -q 'NVM_DIR' "$HOME_DIR/.profile" 2>/dev/null; then
    cat >> "$HOME_DIR/.profile" <<'PROFILE'

# vps-plus: make node available to non-interactive login shells too
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
PROFILE
    chown "$DEPLOY_USER:$DEPLOY_USER" "$HOME_DIR/.profile"
    ok "node on PATH for login shells"
fi
