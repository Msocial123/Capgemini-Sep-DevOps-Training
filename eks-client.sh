#!/bin/bash
# install-eks-clients-al2023.sh
# For Amazon Linux 2023 (al2023). Run as root.

set -o errexit
set -o pipefail
set -o nounset

R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"

LOG_DIR="/home/ec2-user/eks-client-install"
LOG="${LOG_DIR}/eks-client-install.log"
mkdir -p "${LOG_DIR}"
: > "${LOG}"

echo -e "${Y}Starting EKS client install (log: ${LOG})${N}"

USER_ID=$(id -u)
if [ "${USER_ID}" -ne 0 ]; then
    echo -e "${R} You are not the root user, you don't have permission to run this script. ${N}"
    exit 1
fi

VALIDATE() {
    if [ $1 -ne 0 ]; then
        echo -e "$2 ... $R FAILED $N" | tee -a "${LOG}"
        exit 1
    else
        echo -e "$2 ... $G SUCCESS $N" | tee -a "${LOG}"
    fi
}

info() { echo -e "$Y[INFO] $* $N" | tee -a "${LOG}"; }
okmsg() { echo -e "$G[OK] $* $N" | tee -a "${LOG}"; }
errmsg() { echo -e "$R[ERR] $* $N" | tee -a "${LOG}"; }

# detect arch for downloads
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ARCH_DL="amd64" ;;
  aarch64|arm64) ARCH_DL="arm64" ;;
  *) ARCH_DL="${ARCH}" ;;
esac

# ensure essential tools are available
info "Installing prerequisites (curl, unzip, tar, gzip)..."
dnf -y install curl unzip tar gzip coreutils &>> "${LOG}"
VALIDATE $? "Installed prerequisites"

# -------------------------------
# STEP 1: Install Docker on Amazon Linux 2023
# -------------------------------
info "Installing Docker..."
dnf -y install docker &>> "${LOG}"
VALIDATE $? "Installed Docker package"

info "Enabling & starting Docker service..."
systemctl enable --now docker &>> "${LOG}"
VALIDATE $? "Docker service started & enabled"

# Add ec2-user to docker group (if exists)
TARGET_USER="ec2-user"
if id "${TARGET_USER}" &>/dev/null; then
    usermod -aG docker "${TARGET_USER}"
    VALIDATE $? "Added ${TARGET_USER} to docker group"
else
    info "User ${TARGET_USER} not found; skipping group modification"
fi

# -------------------------------
# STEP 2: Install AWS CLI v2
# -------------------------------
info "Installing AWS CLI v2..."
AWSCLI_ZIP="awscliv2.zip"
AWSCLI_URL_X86="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
AWSCLI_URL_ARM="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"

if [ "${ARCH_DL}" = "arm64" ]; then
    AWSCLI_URL="${AWSCLI_URL_ARM}"
else
    AWSCLI_URL="${AWSCLI_URL_X86}"
fi

curl -fsSLo "${LOG_DIR}/${AWSCLI_ZIP}" "${AWSCLI_URL}" &>> "${LOG}"
VALIDATE $? "Downloaded AWS CLI v2 archive"

# remove any previous install temp
[ -d "${LOG_DIR}/aws" ] && rm -rf "${LOG_DIR}/aws" || true

unzip -o "${LOG_DIR}/${AWSCLI_ZIP}" -d "${LOG_DIR}" &>> "${LOG}"
VALIDATE $? "Unzipped AWS CLI archive"

# install (will update if already installed)
"${LOG_DIR}/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update &>> "${LOG}"
VALIDATE $? "Installed AWS CLI v2"

# -------------------------------
# STEP 3: Install eksctl (latest release redirect)
# -------------------------------
info "Installing eksctl (latest)..."
# GitHub provides redirect for "latest/download/eksctl_<OS>_amd64.tar.gz"
EKSCTL_TMP="/tmp/eksctl_${ARCH_DL}.tar.gz"
curl -fsSL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_${ARCH_DL}.tar.gz" -o "${EKSCTL_TMP}" &>> "${LOG}"
VALIDATE $? "Downloaded eksctl tarball"

tar -xzf "${EKSCTL_TMP}" -C /tmp &>> "${LOG}"
VALIDATE $? "Extracted eksctl"

if [ -f /tmp/eksctl ]; then
    if [ -f /usr/local/bin/eksctl ]; then
        mv /usr/local/bin/eksctl /usr/local/bin/eksctl.bak.$(date +%s) &>> "${LOG}" || true
    fi
    mv /tmp/eksctl /usr/local/bin/eksctl &>> "${LOG}"
    chmod +x /usr/local/bin/eksctl &>> "${LOG}"
    VALIDATE $? "Installed eksctl to /usr/local/bin"
else
    errmsg "eksctl binary not found after extract" && exit 1
fi

# -------------------------------
# STEP 4: Install kubectl (latest stable)
# -------------------------------
info "Installing kubectl (latest stable)..."

# fetch stable version tag
K8S_STABLE_TAG="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || true
if [ -z "${K8S_STABLE_TAG}" ]; then
    # fallback to a widely compatible version if the fetch fails
    K8S_STABLE_TAG="v1.27.0"
    info "Could not fetch stable version; falling back to ${K8S_STABLE_TAG}"
else
    info "Latest stable kubectl version: ${K8S_STABLE_TAG}"
fi

KUBECTL_URL="https://dl.k8s.io/release/${K8S_STABLE_TAG}/bin/linux/${ARCH_DL}/kubectl"
KUBECTL_TMP="${LOG_DIR}/kubectl"

curl -fsSL "${KUBECTL_URL}" -o "${KUBECTL_TMP}" &>> "${LOG}"
VALIDATE $? "Downloaded kubectl ${K8S_STABLE_TAG}"

chmod +x "${KUBECTL_TMP}" &>> "${LOG}"
mv "${KUBECTL_TMP}" /usr/local/bin/kubectl &>> "${LOG}"
VALIDATE $? "Installed kubectl to /usr/local/bin"

# verify versions
info "Verifying installed tools..."
docker --version | tee -a "${LOG}" || true
okmsg "Docker version printed"

eksctl version 2>> "${LOG}" || true
okmsg "eksctl version printed"

kubectl version --client --short 2>> "${LOG}" || true
okmsg "kubectl client version printed"

aws --version 2>> "${LOG}" || true
okmsg "aws CLI version printed"

info "Cleaning up temporary files..."
rm -f "${LOG_DIR}/${AWSCLI_ZIP}" "${EKSCTL_TMP}" || true

echo -e "$G All tools installed successfully! $N" | tee -a "${LOG}"
echo -e "$Y You should log out and log back in (or run 'newgrp docker') for docker group changes to take effect. $N" | tee -a "${LOG}"
echo -e "$Y Log file: ${LOG} $N"
