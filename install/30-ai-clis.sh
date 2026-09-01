#!/usr/bin/env bash
# The four agents you actually work in. All installed as the deploy user — none
# of them should ever run as root, and none of them need to.
#
# Authentication is NOT done here. Credentials arrive in stage 40 from the
# encrypted bundle; if you skip that, each CLI prompts on first launch.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_AI_CLIS:-1}" "ai-clis" && exit 0

HOME_DIR="$(deploy_home)"
NODE='source $HOME/.nvm/nvm.sh &&'

have() { as_deploy "$NODE command -v $1" >/dev/null 2>&1; }

# --- Claude Code ------------------------------------------------------------
# The native installer puts a self-updating binary in ~/.local/bin, which
# avoids the npm-global-permissions mess entirely.
if have claude; then
    ok "claude code: $(as_deploy "$NODE claude --version" 2>/dev/null | head -1)"
else
    info "installing claude code"
    as_deploy 'curl -fsSL https://claude.ai/install.sh | bash' \
        || warn "claude installer failed — fall back to: npm i -g @anthropic-ai/claude-code"
fi

# --- Gemini CLI -------------------------------------------------------------
if have gemini; then
    ok "gemini cli: $(as_deploy "$NODE gemini --version" 2>/dev/null | head -1)"
else
    info "installing gemini cli"
    as_deploy "$NODE npm install -g @google/gemini-cli" >/dev/null \
        || warn "gemini cli install failed"
fi

# --- Codex ------------------------------------------------------------------
if have codex; then
    ok "codex: $(as_deploy "$NODE codex --version" 2>/dev/null | head -1)"
else
    info "installing codex"
    as_deploy "$NODE npm install -g @openai/codex" >/dev/null \
        || warn "codex install failed"
fi

# --- Hermes Agent -----------------------------------------------------------
# Hermes is a Python app managed by uv; its installer creates a git checkout at
# $HERMES_HOME/hermes-agent. On Linux HERMES_HOME defaults to ~/.hermes, which
# is where stage 40 restores your config.
if have hermes; then
    ok "hermes: $(as_deploy "$NODE hermes --version" 2>/dev/null | head -1)"
else
    info "installing hermes agent (this pulls python deps — slowest step here)"
    as_deploy 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' \
        || warn "hermes install failed — see https://github.com/NousResearch/hermes-agent"
fi

# --- supporting tools -------------------------------------------------------
# Used by the repos themselves rather than by the agents: vercel for the sites
# still on Vercel during cutover, and the mermaid/pdf helpers your CLAUDE.md
# workflow leans on.
for pkg in vercel@latest; do
    as_deploy "$NODE npm install -g $pkg" >/dev/null 2>&1 || warn "optional: $pkg failed"
done

printf '\n'
warn "None of these are logged in yet."
warn "  claude  — run 'claude' once and complete the browser flow, or restore ~/.claude/.credentials.json (stage 40)"
warn "  gemini  — 'gemini' then /auth, or set GEMINI_API_KEY"
warn "  codex   — 'codex login', or set OPENAI_API_KEY"
warn "  hermes  — restored ~/.hermes/auth.json covers it (stage 40)"
