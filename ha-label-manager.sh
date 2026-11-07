#!/bin/sh
# HA labels sidecar of the Zabbix Helm chart (zabbixServer.zabbixServerHA.enabled=true).
#
# Runs in the Zabbix Server pod, which shares the process namespace (shareProcessNamespace: true), counts the
# zabbix_server processes and sets a label on its own pod: "active" when the Zabbix Server is the active HA node, which
# runs all the Zabbix processes, or "standby" when it runs only the HA manager and a few other processes. The Service
# of the chart selects only the pod with the "active" label. See README.md.
#
# Variables:
#   LABEL_NAME                 label set on the pod (required). The chart uses zabbix.com/server-ha-role
#   POD_NAME                   name of the pod (default: the hostname, which is the name of the pod by default)
#   ACTIVE_PROCESS_THRESHOLD   the node is active with more zabbix_server processes than this number (default: 5)
#   SLEEP_TIME                 seconds between checks (default: 5)
#   LABEL_REFRESH_INTERVAL     seconds between reads of the current label from the Kubernetes API (default: 300)

set -u

pod_name="${POD_NAME:-$(hostname)}"
label_name="${LABEL_NAME:-}"
threshold="${ACTIVE_PROCESS_THRESHOLD:-5}"
sleep_time="${SLEEP_TIME:-5}"
refresh_interval="${LABEL_REFRESH_INTERVAL:-300}"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

if [ -z "${label_name}" ] || [ -z "${pod_name}" ]; then
    log "ERROR: LABEL_NAME and POD_NAME (or the hostname) must be set"
    exit 1
fi

# Stop quickly when the pod is deleted: as PID 1, the shell ignores SIGTERM without a trap
trap 'log "received a signal, stopping"; exit 0' TERM INT

# Number of processes whose command line contains zabbix_server. Zabbix changes the command line of its processes to
# describe them, e.g. "/usr/sbin/zabbix_server: poller #1 [got 0 values in 0.00 sec, idle 5 sec]"
count_zabbix_processes() {
    count=0
    for cmdline in /proc/[0-9]*/cmdline; do
        # processes can end during the loop
        args=$(tr '\0' ' ' < "${cmdline}" 2>/dev/null) || continue
        case "${args}" in
            *zabbix_server*) count=$((count + 1)) ;;
        esac
    done
    echo "${count}"
}

# Current value of the label, read from the Kubernetes API. Dots of the label name are escaped for jsonpath
read_label() {
    escaped=$(echo "${label_name}" | sed 's/\./\\./g')
    kubectl get pod "${pod_name}" -o "jsonpath={.metadata.labels['${escaped}']}"
}

log "starting the HA label manager: pod ${pod_name}, label ${label_name}, threshold ${threshold} processes"

label_value=""
last_label_read=0
while true; do
    now=$(date +%s)
    if [ $((now - last_label_read)) -ge "${refresh_interval}" ]; then
        if current=$(read_label); then
            label_value="${current}"
            last_label_read=${now}
            log "got the label value '${label_value}' from the Kubernetes API"
        else
            log "ERROR: could not read the labels of the pod ${pod_name}"
        fi
    fi

    processes=$(count_zabbix_processes)
    if [ "${processes}" -gt "${threshold}" ]; then
        role="active"
    else
        role="standby"
    fi

    if [ "${role}" != "${label_value}" ]; then
        log "${processes} zabbix_server processes running (threshold ${threshold}): setting the label ${label_name} from '${label_value}' to '${role}'"
        if kubectl label pod "${pod_name}" "${label_name}=${role}" --overwrite; then
            label_value="${role}"
        else
            # keeps the old value, so the next check tries again
            log "ERROR: could not set the label ${label_name} of the pod ${pod_name}"
        fi
    fi

    # sleep in the background, so the trap runs as soon as a signal arrives
    sleep "${sleep_time}" &
    wait $!
done
