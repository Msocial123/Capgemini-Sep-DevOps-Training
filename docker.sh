#!/usr/bin/env bash
#
# install-docker-aws-al2023.sh
# Installs Docker, Docker Compose (plugin preferred, fallback to standalone),
# adds non-root user to docker group, and installs AWS CLI v2.
#
# Target: Amazon Linux 2023 (al2023) - uses dnf
# Usage:
#   sudo /usr/local/bin/install-docker-aws-al2023.sh [target_user]
#
# If target_user is not provided, the script uses:
# 1) SUDO_USER (when invoked with sudo) or
# 2) 'ec2-user' as fallback.

set -o errexit
set -o pipefail
set -o nounset

# Colors
R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"

LOG_DIR="/var/log/install-docker-aws"
LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"
: > "${LOG}"

info()  { echo -e "${Y}[INFO] $*${N}" | tee -a "${LOG}"; }
ok()    { echo -e "${G}[OK]   $*${N}" | tee -a "${LOG}"; }
fail()  { echo -e "${R}[FAIL] $*${N}" | tee -a "${LOG}"; exit 1; }

VALIDATE() {
  if [ "$1" -ne 0 ]; then
    fail "$2 (see ${LOG})"
  else
    ok "$2"
  fi
}

# Determine target user to add to docker group
TARGET_USER="${1:-}"
if [ -z "${TARGET_USER}" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="${SUDO_USER}"
  else
    TARGET_USER="ec2-user"
  fi
fi

# Root check
if [ "$(id -u)" -ne 0 ]; then
  fail "This script must be run as root (use sudo)."
fi

info "Starting installation. Log: ${LOG}"
info "Target non-root user to add to docker group: ${TARGET_USER}"

# Determine arch for downloads
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ARCH_DL="amd64" ;;
  aarch64|arm64) ARCH_DL="arm64" ;;
  *) ARCH_DL="${ARCH}" ;;
esac
info "Detected architecture: ${ARCH} -> download arch: ${ARCH_DL}"

# Install base utilities
info "Installing prerequisites (curl, unzip, tar, gzip, ca-certificates)..."
dnf -y update &>> "${LOG}"
dnf -y install curl unzip tar gzip ca-certificates &>> "${LOG}"
VALIDATE $? "Installed prerequisites and updated packages"

# ---------------------------
# Install Docker
# ---------------------------
info "Installing Docker package via dnf..."
dnf -y install docker &>> "${LOG}" || fail "Failed to install docker package"
ok "Docker package installed"

info "Enabling & starting Docker..."
systemctl enable --now docker &>> "${LOG}"
VALIDATE $? "Docker service enabled & started"

# Add target user to docker group if user exists
if id "${TARGET_USER}" &>/dev/null; then
  usermod -aG docker "${TARGET_USER}" &>> "${LOG}"
  VALIDATE $? "Added ${TARGET_USER} to docker group"
else
  info "User ${TARGET_USER} not found; skipping docker group addition"
fi

# ---------------------------
# Install docker-compose
# Preferred: docker compose plugin (dnf package). Fallback: standalone binary.
# ---------------------------
info "Attempting to install docker-compose plugin from package..."
dnf -y install docker-compose-plugin &>> "${LOG}" || true

if command -v docker >/dev/null 2>&1 && docker compose version &>/dev/null 2>&1 ; then
  ok "Using docker compose plugin (invoke with: docker compose ...)"
else
  info "docker compose plugin not available; installing standalone docker-compose binary"
  COMPOSE_BIN="/usr/local/bin/docker-compose"
  COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
  info "Downloading docker-compose from ${COMPOSE_URL} ..."
  curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_BIN}" &>> "${LOG}"
  VALIDATE $? "Downloaded docker-compose binary to ${COMPOSE_BIN}"
  chmod +x "${COMPOSE_BIN}" &>> "${LOG}"
  VALIDATE $? "Set executable permission on ${COMPOSE_BIN}"
  # Symlink for compatibility
  if [ ! -f /usr/bin/docker-compose ]; then
    ln -s "${COMPOSE_BIN}" /usr/bin/docker-compose &>> "${LOG}" || true
  fi
  ok "Standalone docker-compose installed (command: docker-compose or 'docker compose' if plugin installed later)"
fi

# ---------------------------
# Install AWS CLI v2
# ---------------------------
info "Installing AWS CLI v2..."
AWSZIP="/tmp/awscliv2.zip"
if [ "${ARCH_DL}" = "arm64" ]; then
  AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
  AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
fi

info "Downloading AWS CLI from ${AWS_URL} ..."
curl -fsSL "${AWS_URL}" -o "${AWSZIP}" &>> "${LOG}"
VALIDATE $? "Downloaded AWS CLI archive to ${AWSZIP}"

# cleanup any previous extracted dir then extract & install
rm -rf /tmp/aws_install_dir &>> "${LOG}" || true
unzip -o "${AWSZIP}" -d /tmp/aws_install_dir &>> "${LOG}"
VALIDATE $? "Unzipped AWS CLI archive"

# Run installer
/tmp/aws_install_dir/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update &>> "${LOG}"
VALIDATE $? "Installed/Updated AWS CLI v2"

# ---------------------------
# Final verification
# ---------------------------
info "Verifying installed binaries..."

if command -v docker >/dev/null 2>&1; then
  docker --version | tee -a "${LOG}"
  ok "docker version printed"
else
  fail "docker not found"
fi

# Check compose plugin first, then standalone
if docker compose version &>/dev/null 2>&1; then
  docker compose version | tee -a "${LOG}"
  ok "docker compose (plugin) available"
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose --version | tee -a "${LOG}"
  ok "docker-compose (standalone) available"
else
  fail "docker compose not available"
fi

if command -v aws >/dev/null 2>&1; then
  aws --version | tee -a "${LOG}"
  ok "aws CLI v2 available"
else
  fail "aws CLI not found"
fi

# Suggest next steps to user
echo
echo -e "${G}Installation completed.${N}"
echo -e "${Y}Notes:${N}"
echo -e "  * If you added a user (${TARGET_USER}) to the docker group, that user must re-login or run 'newgrp docker' for group membership to take effect."
echo -e "  * Log file: ${LOG}"
echo
exit 0
