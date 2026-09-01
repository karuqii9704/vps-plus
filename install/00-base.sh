#!/usr/bin/env bash
# Base hardening and housekeeping. Nothing app-specific — this stage is what
# any VPS wants on its first hour: a non-root user, a firewall, swap, and
# automatic security patches.

source "$ROOT/lib/common.sh"
load_conf "$ROOT"

skip_unless "${INSTALL_BASE:-1}" "base" && exit 0

info "apt update + core packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl wget git rsync unzip zip jq \
    build-essential pkg-config \
    ufw fail2ban unattended-upgrades \
    htop ncdu tmux ripgrep age \
    python3 python3-venv python3-pip \
    postgresql-client
ok "packages installed"

info "timezone -> ${TIMEZONE}"
timedatectl set-timezone "$TIMEZONE" || warn "could not set timezone"

# --- deploy user ------------------------------------------------------------
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    log "user $DEPLOY_USER already exists"
else
    info "creating user $DEPLOY_USER"
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"

# Carry root's SSH keys over so you are never locked out after disabling root
# login. Skipped when the user already has their own authorized_keys.
HOME_DIR="$(deploy_home)"
if [[ -s /root/.ssh/authorized_keys && ! -s "$HOME_DIR/.ssh/authorized_keys" ]]; then
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$HOME_DIR/.ssh"
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
        /root/.ssh/authorized_keys "$HOME_DIR/.ssh/authorized_keys"
    ok "copied root's authorized_keys to $DEPLOY_USER"
fi

# Passwordless sudo for the deploy user: ops/deploy.sh and the AI CLIs need to
# restart containers and reload nginx without an interactive prompt.
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEPLOY_USER" > /etc/sudoers.d/90-vps-plus
chmod 440 /etc/sudoers.d/90-vps-plus
visudo -cf /etc/sudoers.d/90-vps-plus >/dev/null || die "bad sudoers file"

# --- directories ------------------------------------------------------------
for d in "$SRV_ROOT" "$REPOS_DIR" "$DATA_DIR" "$DATA_DIR/backups"; do
    install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$d"
done
ok "created $SRV_ROOT, $REPOS_DIR, $DATA_DIR"

# --- swap -------------------------------------------------------------------
# `next build` on a 2 GB droplet is the classic OOM kill. Swap is slower than
# RAM and infinitely faster than a failed build.
if [[ "${SWAP_SIZE_GB:-0}" != "0" ]] && ! swapon --show | grep -q .; then
    info "creating ${SWAP_SIZE_GB}G swapfile"
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024))
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -qw vm.swappiness=10
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    ok "swap active"
fi

# --- firewall ---------------------------------------------------------------
# Default deny inbound. Only SSH and the two web ports are open; Postgres and
# every app port stay on loopback and are reachable through nginx alone.
info "ufw"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT:-22}"/tcp comment 'ssh' >/dev/null
ufw allow 80/tcp  comment 'http'  >/dev/null
ufw allow 443/tcp comment 'https' >/dev/null
ufw --force enable >/dev/null
ok "firewall: $(ufw status | grep -c ALLOW) rules, default deny"

# --- fail2ban + unattended upgrades ----------------------------------------
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban not started"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
ok "fail2ban + unattended security upgrades enabled"

warn "root SSH login is NOT disabled automatically."
warn "Verify 'ssh ${DEPLOY_USER}@<ip>' works, then: sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && sudo systemctl reload ssh"
