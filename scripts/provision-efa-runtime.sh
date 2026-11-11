#!/bin/sh
# provision-efa-runtime.sh
#
# Installs the AWS EFA user-space stack (libfabric + EFA provider, aws-ofi-nccl,
# OpenMPI) into /opt/amazon and copies the rdma-core / netlink libraries it
# depends on into /opt/amazon/efa/lib64 so the result is self-contained.
#
# Intended to run inside a Kubernetes init container whose shared volume
# (emptyDir) is mounted at /opt/amazon. The application container then mounts
# the efa/, ofi-nccl/ and openmpi/ sub-paths read-only.
#
# Environment variables:
#   EFA_INSTALLER_VERSION  Installer version to download (default: "latest").
#                          Pin this (e.g. "1.38.0") for reproducible builds.
#   EFA_TARGET_DIR         Install prefix (default: /opt/amazon). Must match
#                          the init container's volume mount path.

set -e

EFA_INSTALLER_VERSION="${EFA_INSTALLER_VERSION:-latest}"
EFA_TARGET_DIR="${EFA_TARGET_DIR:-/opt/amazon}"
EFA_LIB_DIR="${EFA_TARGET_DIR}/efa/lib64"
INSTALLER_URL="https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz"

echo "[Platform] Installing EFA userspace libraries (installer: ${EFA_INSTALLER_VERSION})..."

# Prerequisites for a minimal Amazon Linux 2023 image.
yum install -y tar gzip libatomic util-linux findutils which --allowerasing

# Download and run the EFA installer.
#   -y  non-interactive
#   -k  skip kernel module install; the host AMI already loads the EFA driver
#       and containers share the host kernel, so only user space is needed.
cd /tmp
curl -fsSL "${INSTALLER_URL}" -o efa-installer.tar.gz
tar -xzf efa-installer.tar.gz
cd aws-efa-installer
./efa_installer.sh -y -k

# The EFA provider (libefa-fi.so) links against rdma-core (libibverbs,
# librdmacm) and netlink (libnl-3, libnl-route). The installer puts these in
# /usr/lib64, which is NOT on the shared volume. Copy them next to libfabric
# so the user container does not need rdma-core installed.
echo "[Platform] Copying rdma-core + EFA provider libs into ${EFA_LIB_DIR}/..."
for lib in libefa libibverbs librdmacm libnl-3 libnl-route; do
  cp -a /usr/lib64/${lib}* "${EFA_LIB_DIR}/" 2>/dev/null || true
done
ls -la "${EFA_LIB_DIR}"/libefa* "${EFA_LIB_DIR}"/libibverbs*

echo "[Platform] Installed components:"
ls "${EFA_TARGET_DIR}/"

echo "[Platform] EFA Version Manifest:"
grep "Version" "${EFA_LIB_DIR}/pkgconfig/libfabric.pc" 2>/dev/null || true
find "${EFA_TARGET_DIR}/ofi-nccl" -name "libnccl-net*" -exec ls -la {} \; 2>/dev/null || true
