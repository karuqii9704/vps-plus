#!/usr/bin/env bash
# Clones the four applications into $REPOS_DIR. Existing checkouts are fetched
# and fast-forwarded, never reset: local work on the VPS is not thrown away by
# a re-run of bootstrap.
#
# Private repos need credentials. Either put a GitHub token in the environment
# (GH_TOKEN=ghp_...) or drop an SSH key at ~/.ssh/id_ed25519 before this stage.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_REPOS:-1}" "repos" && exit 0

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$REPOS_DIR"

# git refuses to operate in a directory owned by another user; the deploy user
# owns these, and everything below runs as them.
as_deploy "git config --global --add safe.directory '*'" >/dev/null 2>&1 || true
as_deploy "git config --global pull.ff only" >/dev/null 2>&1 || true

# Token auth is injected per-command rather than written into .git/config, so a
# `git remote -v` never leaks it.
git_env=""
if [[ -n "${GH_TOKEN:-}" ]]; then
    log "using GH_TOKEN for HTTPS clones"
    git_env="GIT_ASKPASS=/bin/echo GIT_TERMINAL_PROMPT=0"
    as_deploy "git config --global url.'https://x-access-token:${GH_TOKEN}@github.com/'.insteadOf 'https://github.com/'" >/dev/null
fi

clone_or_update() {
    local key="$1" url branch dir path
    url="$(app_var "$key" REPO)"
    branch="$(app_var "$key" BRANCH)"
    dir="$(app_dir_name "$key")"
    path="$REPOS_DIR/$dir"

    if [[ -z "$url" ]]; then
        warn "$key: no REPO_$(echo "$key" | tr a-z A-Z) in vps.conf — skipped"
        return 0
    fi

    if [[ -d "$path/.git" ]]; then
        info "$key: updating $dir"
        as_deploy "$git_env git -C '$path' fetch --prune origin" >/dev/null
        # Fast-forward only. A diverged checkout stops here loudly instead of
        # silently discarding whatever was edited on the server.
        if ! as_deploy "git -C '$path' merge --ff-only 'origin/${branch}'" >/dev/null 2>&1; then
            warn "$key: cannot fast-forward $dir to origin/$branch (local commits or dirty tree)"
            warn "      inspect it: git -C $path status"
            return 0
        fi
        ok "$key: $(as_deploy "git -C '$path' log -1 --format='%h %s'" | cut -c1-60)"
    else
        info "$key: cloning $url"
        as_deploy "$git_env git clone --branch '$branch' '$url' '$path'" >/dev/null 2>&1 \
            || { warn "$key: clone failed (private repo? set GH_TOKEN)"; return 0; }
        ok "$key: cloned to $path"
    fi
}

for key in "${APP_KEYS[@]}"; do
    clone_or_update "$key"
done

# --- skills vault -----------------------------------------------------------
# Stage 40 rsyncs the vault out of the bundle. If it has since been pushed to
# GitHub, prefer the repo so `git pull` keeps the VPS in sync.
if [[ -n "${REPO_SKILLS_VAULT:-}" ]]; then
    if [[ -d /srv/skills-vault/.git ]]; then
        if as_deploy "git -C /srv/skills-vault pull --ff-only" >/dev/null 2>&1; then
            ok "skills vault updated"
        else
            warn "skills vault: cannot fast-forward — left as-is"
        fi
    else
        # Stage 40 may have put a plain file copy here; keep it rather than
        # letting the clone fail on a non-empty directory.
        if [[ -d /srv/skills-vault ]]; then
            mv /srv/skills-vault "/srv/skills-vault.files-$(date +%s)"
        fi
        if as_deploy "git clone '$REPO_SKILLS_VAULT' /srv/skills-vault" >/dev/null 2>&1; then
            ok "skills vault cloned from git"
        else
            warn "skills vault clone failed: $REPO_SKILLS_VAULT"
        fi
    fi
fi

printf '\n'
as_deploy "ls -1 '$REPOS_DIR'" | sed 's/^/  /'
