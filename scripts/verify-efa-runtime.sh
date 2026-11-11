#!/usr/bin/env bash
# verify-efa-runtime.sh
#
# Checks that the Platform-Managed EFA Runtime was provisioned into a running worker pod and that
# libfabric can see the EFA provider.
#
# Usage: scripts/verify-efa-runtime.sh <pod-name> [namespace] [container]
#   e.g. scripts/verify-efa-runtime.sh distributed-training-job-worker-0

set -euo pipefail

POD="${1:?usage: $0 <pod-name> [namespace] [container]}"
NS="${2:-default}"
CONTAINER="${3:-worker}"

kx() { kubectl exec -n "$NS" "$POD" -c "$CONTAINER" -- "$@"; }

echo "== Init container log (EFA version manifest) =="
kubectl logs -n "$NS" "$POD" -c efa-installer | sed -n '/\[Platform\] Installed components/,$p'

echo
echo "== Platform-provided directories =="
kx ls -d /opt/amazon/efa /opt/amazon/ofi-nccl /opt/amazon/openmpi

echo
echo "== rdma-core / netlink libraries present in /opt/amazon/efa/lib64 =="
kx sh -c 'ls /opt/amazon/efa/lib64 | grep -E "^(libefa|libibverbs|librdmacm|libnl-3|libnl-route)" '

echo
echo "== aws-ofi-nccl plugin =="
kx sh -c 'find /opt/amazon/ofi-nccl -name "libnccl-net*"'

echo
echo "== EFA devices visible to libfabric (fi_info -p efa) =="
kx sh -c 'FI_PROVIDER_PATH=/opt/amazon/efa/lib64/libfabric /opt/amazon/efa/bin/fi_info -p efa -t FI_EP_RDM' | head -n 20

echo
echo "OK: EFA runtime provisioned and EFA provider is usable in ${NS}/${POD}"
