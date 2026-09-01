#!/usr/bin/env bash
# Update the four AI CLIs in place. Separate from bootstrap because you will
# run this far more often than you will re-provision the box.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_conf "$ROOT"

NODE='source $HOME/.nvm/nvm.sh &&'

step "claude code"
# The native install is self-updating; `claude update` is the supported path.
as_deploy "$NODE claude update" 2>&1 | sed 's/^/  /' || warn "claude update failed"

step "gemini cli"
as_deploy "$NODE npm install -g @google/gemini-cli" >/dev/null && ok "$(as_deploy "$NODE gemini --version" | head -1)"

step "codex"
as_deploy "$NODE npm install -g @openai/codex" >/dev/null && ok "$(as_deploy "$NODE codex --version" | head -1)"

step "hermes"
# Hermes ships its own updater against the git checkout it installed from.
as_deploy "$NODE hermes update" 2>&1 | sed 's/^/  /' || warn "hermes update failed"

printf '\n'
"$ROOT/ops/status.sh" 2>/dev/null | sed -n '/agents/,$p'
