#!/usr/bin/env bash
# Docker Engine + the compose plugin, from Docker's own apt repository.
# Ubuntu's docker.io package lags and ships no `docker compose`.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_DOCKER:-1}" "docker" && exit 0

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "already present: $(docker --version), $(docker compose version --short)"
else
    info "adding docker apt repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

    # Docker publishes per Ubuntu codename, and a brand-new release can land
    # months before they do. Checking turns "apt-get update failed" into a
    # sentence that says what to do about it.
    if ! curl -fsS -o /dev/null "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release"; then
        die "Docker has no repository for Ubuntu '${CODENAME}' yet.
     Either wait for it, or pin the previous LTS by hand:
       echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list
     then re-run: sudo \$ROOT/bootstrap.sh --force 10"
    fi
    log "docker repository: ${CODENAME}"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    ok "installed $(docker --version)"
fi

usermod -aG docker "$DEPLOY_USER"
log "$DEPLOY_USER added to the docker group (takes effect on next login)"

# Unbounded json logs are the most common way a small VPS fills its disk.
if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d /etc/docker
    cat > /etc/docker/daemon.json <<'CONF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
CONF
    systemctl restart docker
    ok "log rotation capped at 30M per container"
fi

systemctl enable --now docker >/dev/null
docker run --rm hello-world >/dev/null 2>&1 && ok "docker runs containers" \
    || die "docker is installed but cannot run a container"
