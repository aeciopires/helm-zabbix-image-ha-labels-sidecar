#!/usr/bin/env bash
# End-to-end test of the image in a kind cluster: the sidecar must label its pod as standby, active and standby again,
# following the number of zabbix_server processes of a fake Zabbix Server container. See docs/local-tests.md.
#
# Variables:
#   IMAGE              image to test (default: zabbix-server-ha-label-manager:local). It is loaded into the cluster
#   KIND_CLUSTER_NAME  kind cluster, created if it doesn't exist (default: helm-zabbix-image-ha-labels-sidecar)
#   NAMESPACE          namespace of the test, deleted at the end (default: ha-labels-sidecar-test)

set -euo pipefail

IMAGE="${IMAGE:-zabbix-server-ha-label-manager:local}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-helm-zabbix-image-ha-labels-sidecar}"
NAMESPACE="${NAMESPACE:-ha-labels-sidecar-test}"
LABEL="zabbix.com/server-ha-role"
POD="ha-labels-sidecar-test"
DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "### $(date -u +%H:%M:%S) $*"; }

if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    log "creating the kind cluster ${KIND_CLUSTER_NAME}"
    kind create cluster --name "${KIND_CLUSTER_NAME}" --wait 180s
fi
CONTEXT="kind-${KIND_CLUSTER_NAME}"
k() { kubectl --context "${CONTEXT}" --namespace "${NAMESPACE}" "$@"; }

log "loading the image ${IMAGE} into the cluster ${KIND_CLUSTER_NAME}"
kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER_NAME}"

cleanup() {
    log "pod logs"
    k logs "${POD}" --all-containers --prefix --tail=30 2>/dev/null || true
    kubectl --context "${CONTEXT}" delete namespace "${NAMESPACE}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl --context "${CONTEXT}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f - >/dev/null
sed "s|image: zabbix-server-ha-label-manager:local|image: ${IMAGE}|" "${DIR}/kind-test.yaml" | k apply -f -
k wait pod "${POD}" --for=condition=Ready --timeout=180s

# waits until the label of the pod has the value $1, at most $2 seconds
wait_label() {
    local expected="$1" timeout="$2" start value
    start=$(date +%s)
    while true; do
        value=$(k get pod "${POD}" -o "jsonpath={.metadata.labels['zabbix\.com/server-ha-role']}")
        if [[ $value == "$expected" ]]; then
            log "PASS: label ${LABEL}=${value} after $(( $(date +%s) - start ))s"
            return 0
        fi
        if (( $(date +%s) - start >= timeout )); then
            log "FAIL: label ${LABEL}='${value}', expected '${expected}' after ${timeout}s"
            exit 1
        fi
        sleep 2
    done
}

wait_label standby 40
wait_label active 60
wait_label standby 60

log "deleting the pod: the sidecar must stop quickly on SIGTERM"
start=$(date +%s)
k delete pod "${POD}" --wait=true --timeout=60s >/dev/null
elapsed=$(( $(date +%s) - start ))
if (( elapsed > 15 )); then
    log "FAIL: the pod took ${elapsed}s to stop"
    exit 1
fi
log "PASS: the pod stopped in ${elapsed}s"
log "all checks passed"
