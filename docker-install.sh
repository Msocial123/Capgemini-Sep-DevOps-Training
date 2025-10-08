#!/bin/bash
# install-docker-al2023.sh
# Designed for Amazon Linux 2023 (ID=amzn, VERSION_ID starts with 2023).
# Run as root.

set -o errexit
set -o pipefail
set -o nounset

R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"

LOG="/var/log/docker-install-$(date +%Y%m%d-%H%M%S).log"
exec 1>>"$LOG" 2>&1

info() { echo -e "$Y[INFO] $* $N"; }
ok()   { echo -e "$G[OK]   $* $N"; }
err()  { echo -e "$R[ERROR] $* $N"; }

VALIDATE(){
    local rc=$1
    local msg="$2"
    if [ "$rc" -ne 0 ]; then
        err "$msg ... FAILED (see $LOG)"
        exit 1
    else
        ok "$msg ... SUCCESS"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    err "You are not root. Please run as root or with sudo."
    exit 1
fi

# Basic platform detection: ensure we are on Amazon Linux 2023 (optional fallback)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    PLATFORM_ID="${ID:-unknown}"
    PLATFORM_VER="${VERSION_ID:-unknown}"
else
    PLATFORM_ID="unknown"
    PLATFORM_VER="unknown"
fi

info "Detected platform: ID=${PLATFORM_ID}, VERSION_ID=${PLATFORM_VER}"

# Update packages (dnf for AL2023)
info "Updating system packages..."
dnf -y update
VALIDATE $? "Updating packages"

# Install prerequisites (docker, git, curl). Try package install via dnf.
info "Installing docker, git and curl..."
dnf -y install docker git curl
VALIDATE $? "Installing docker, git, curl via dnf"

# Start and enable docker
info "Starting and enabling docker service..."
systemctl enable --now docker
VALIDATE $? "Starting & enabling Docker (systemd)"

# Add ec2-user to docker group if ec2-user exists
TARGET_USER="ec2-user"
if id "$TARGET_USER" &>/dev/null; then
    usermod -aG docker "$TARGET_USER"
    VALIDATE $? "Added $TARGET_USER to docker group"
else
    info "User $TARGET_USER not found: skipping usermod (you can add users manually)"
fi

# Try to install docker-compose plugin (preferred modern approach).
info "Attempting to install docker-compose plugin via dnf (if available)..."
dnf -y install docker-compose-plugin || true

if command -v docker compose &>/dev/null; then
    ok "Docker compose plugin is available (use: docker compose ...)"
else
    info "docker compose plugin not found. Falling back to standalone docker-compose binary."

    BIN_PATH="/usr/local/bin/docker-compose"
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"

    info "Downloading docker-compose from: $COMPOSE_URL"
    curl -fsSL "$COMPOSE_URL" -o "$BIN_PATH"
    VALIDATE $? "Downloaded docker-compose binary to $BIN_PATH"

    chmod +x "$BIN_PATH"
    VALIDATE $? "Made $BIN_PATH executable"

    # Create symlink for backward compatibility (docker-compose command)
    if ! command -v docker-compose &>/dev/null; then
        ln -s "$BIN_PATH" /usr/bin/docker-compose || true
    fi
fi

# Final checks
info "Verifying docker and compose versions..."
docker --version
VALIDATE $? "Docker version check"

# prefer 'docker compose' plugin; otherwise 'docker-compose'
if docker compose version &>/dev/null; then
    docker compose version
    ok "docker compose is ready"
elif docker-compose --version &>/dev/null; then
    docker-compose --version
    ok "docker-compose (standalone binary) is ready"
else
    err "docker compose not found after installation"
    exit 1
fi

info "Cleaning up dnf caches..."
dnf -y clean all || true

echo -e "${G}Installation finished.${N}"
echo -e "${Y}You should log out and log back in (or run 'newgrp docker') for group membership to apply.${N}"
echo -e "${Y}Log file: $LOG${N}"
