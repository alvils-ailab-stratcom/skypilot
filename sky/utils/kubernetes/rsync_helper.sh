#!/bin/bash
# SkyPilot rsync remote shell for Kubernetes pods.
#
# This local patch avoids a kubectl exec -i EOF deadlock seen with SSH node
# pools by forwarding pod port 22 and running rsync over real SSH.

set -u

log() {
    echo "[rsync_helper $(date -u +%H:%M:%S)] $*" >&2
}

if ! command -v nc >/dev/null 2>&1; then
    log "Error: netcat (nc) is required but not installed."
    exit 1
fi
url_decode() {
    printf '%s\n' "$1" | sed 's|%40|@|g' | sed 's|%3A|:|g' | sed 's|%2B|+|g' | sed 's|%2F|/|g'
}

if [ "$1" = "-l" ]; then
    shift
    pod=$1
    shift
    encoded_namespace_context=$1
    shift
    echo "pod: $pod" >&2
    namespace_context=$(url_decode "$encoded_namespace_context")
    echo "namespace_context: $namespace_context" >&2
else
    encoded_pod_namespace_context=$1
    shift
    pod_namespace_context=$(url_decode "$encoded_pod_namespace_context")
    echo "pod_namespace_context: $pod_namespace_context" >&2
    pod=$(echo "$pod_namespace_context" | cut -d@ -f1)
    echo "pod: $pod" >&2
    namespace_context=$(echo "$pod_namespace_context" | cut -d@ -f2-)
    echo "namespace_context: $namespace_context" >&2
fi

namespace=$(echo "$namespace_context" | cut -d+ -f1)
echo "namespace: $namespace" >&2
context=$(echo "$namespace_context" | grep '+' >/dev/null && echo "$namespace_context" | cut -d+ -f2- || echo "")
echo "context: $context" >&2
context_lower=$(echo "$context" | tr '[:upper:]' '[:lower:]')
container="${SKYPILOT_K8S_EXEC_CONTAINER:-ray-node}"
echo "container: $container" >&2

if [[ "$pod" == *"/"* ]]; then
    echo "Resource contains type: $pod" >&2
    resource_type=$(echo "$pod" | cut -d/ -f1)
    resource_name=$(echo "$pod" | cut -d/ -f2)
    echo "Resource type: $resource_type, Resource name: $resource_name" >&2
else
    resource_type="pod"
    resource_name=$pod
    echo "Assuming resource is a pod: $resource_name" >&2
fi

# Candidate private keys. A multi-client API server keeps one keypair per
# user hash under ~/.sky/clients/<hash>/ssh/, and a pod's authorized_keys
# holds only the LAUNCHING user's pubkey — taking the first glob match
# (upstream #10033 behavior) offers the wrong client's key whenever more
# than one exists, denying auth for every user. Collect ALL keys and probe;
# SKYPILOT_SSH_KEY pins a single key explicitly.
sky_keys=()
if [ -n "${SKYPILOT_SSH_KEY:-}" ] && [ -f "${SKYPILOT_SSH_KEY}" ]; then
    sky_keys=("${SKYPILOT_SSH_KEY}")
else
    for candidate in "${HOME:-}"/.sky/clients/*/ssh/sky-key; do
        [ -f "$candidate" ] && sky_keys+=("$candidate")
    done
fi
if [ "${#sky_keys[@]}" -eq 0 ]; then
    log "Could not find any SkyPilot SSH key. Set SKYPILOT_SSH_KEY to the pod SSH private key."
    exit 1
fi
chmod 600 "${sky_keys[@]}" 2>/dev/null || true
log "candidate ssh keys: ${sky_keys[*]}"

pick_port() {
    base=$((20000 + ($$ % 20000)))
    i=0
    while [ "$i" -lt 200 ]; do
        port=$((base + i))
        if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

local_port=$(pick_port) || {
    echo "Could not find a free local port for kubectl port-forward." >&2
    exit 1
}

pf_pid=""
pf_log="${TMPDIR:-/tmp}/skypilot-rsync-port-forward-${resource_name}-${local_port}.log"

cleanup() {
    if [ -n "$pf_pid" ]; then
        kill "$pf_pid" >/dev/null 2>&1 || true
        wait "$pf_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pf_log" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [ -z "$context" ] || [ "$context_lower" = "none" ]; then
    kubectl port-forward "$resource_type/$resource_name" -n "$namespace" --kubeconfig=/dev/null --address 127.0.0.1 "${local_port}:22" >"$pf_log" 2>&1 &
else
    kubectl port-forward "$resource_type/$resource_name" -n "$namespace" --context="$context" --address 127.0.0.1 "${local_port}:22" >"$pf_log" 2>&1 &
fi
pf_pid=$!
log "port-forward started: pid ${pf_pid}, ${resource_type}/${resource_name} 127.0.0.1:${local_port} -> 22 (context: ${context:-<in-cluster>})"

count=0
max_count=600
until nc -z 127.0.0.1 "$local_port" >/dev/null 2>&1; do
    if ! kill -0 "$pf_pid" >/dev/null 2>&1; then
        log "FAIL(port-forward): kubectl port-forward exited before port ${local_port} became ready. Log:"
        cat "$pf_log" >&2 2>/dev/null || true
        exit 1
    fi
    if [ "$count" -ge "$max_count" ]; then
        log "FAIL(port-forward): timed out waiting for kubectl port-forward to pod SSH port 22. Log:"
        cat "$pf_log" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.5
    count=$((count + 1))
done
log "port-forward ready after $((count / 2))s"

ssh_opts=(
    -p "$local_port"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    # A kubelet with the kernel-7.0 stream bug can wedge the port-forward
    # data stream mid-transfer (0 bytes, forever) with no error to either
    # side. Keepalives make ssh detect the dead stream in ~60s and exit
    # nonzero, so the caller's rsync retry re-rolls instead of hanging.
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
)

# The pod's startup script writes the LAUNCHING client's public key into the
# CONTAINER DEFAULT USER's ~/.ssh/authorized_keys (and enables root login).
# SkyPilot's own images default to user `sky`; custom images (e.g.
# vllm/vllm-openai) default to root with no `sky` user. Probe every
# (key, user) combination and use the first that authenticates; cache the
# working pair per pod so later invocations skip the scan.
# SKYPILOT_SSH_USER pins the user (still probed against each key).
ssh_user=""
sky_key=""
if [ -n "${SKYPILOT_SSH_USER:-}" ]; then
    users=("${SKYPILOT_SSH_USER}")
else
    users=(sky root)
fi
auth_cache="${TMPDIR:-/tmp}/skypilot-rsync-auth-${resource_name}"
if [ -f "$auth_cache" ]; then
    IFS=$'\t' read -r cached_key cached_user < "$auth_cache" || true
    if [ -n "${cached_key:-}" ] && [ -f "$cached_key" ] && [ -n "${cached_user:-}" ]; then
        if ssh "${ssh_opts[@]}" -i "$cached_key" -o BatchMode=yes \
                "${cached_user}@127.0.0.1" true >/dev/null 2>&1; then
            sky_key=$cached_key
            ssh_user=$cached_user
            log "auth cache hit: ${ssh_user}@ with ${sky_key}"
        else
            log "auth cache stale, rescanning"
            rm -f "$auth_cache" 2>/dev/null || true
        fi
    fi
fi
if [ -z "$ssh_user" ]; then
    for candidate_key in "${sky_keys[@]}"; do
        for candidate_user in "${users[@]}"; do
            probe_out=$(ssh "${ssh_opts[@]}" -i "$candidate_key" -o BatchMode=yes \
                "${candidate_user}@127.0.0.1" true 2>&1)
            probe_rc=$?
            if [ "$probe_rc" -eq 0 ]; then
                sky_key=$candidate_key
                ssh_user=$candidate_user
                printf '%s\t%s\n' "$sky_key" "$ssh_user" > "$auth_cache" 2>/dev/null || true
                log "auth probe: ${candidate_user}@ with ${candidate_key} OK"
                break 2
            fi
            log "auth probe: ${candidate_user}@ with ${candidate_key} failed (rc=${probe_rc}): ${probe_out}"
        done
    done
    if [ -z "$ssh_user" ]; then
        log "FAIL(ssh-auth): no (key, user) combination authenticated. keys: ${sky_keys[*]}; users: ${users[*]}"
        log "Hints: the pod's authorized_keys holds only the launching user's pubkey; set SKYPILOT_SSH_KEY / SKYPILOT_SSH_USER to pin. port-forward log:"
        cat "$pf_log" >&2 2>/dev/null || true
        exit 255
    fi
fi
echo "ssh_key: $sky_key" >&2

MAX_WAIT_TIME_SECONDS=300
MAX_WAIT_COUNT=$((MAX_WAIT_TIME_SECONDS * 2))

log "exec rsync transport: ssh ${ssh_user}@127.0.0.1:${local_port} (key: ${sky_key}), remote command: $*"
exec ssh "${ssh_opts[@]}" -i "$sky_key" "${ssh_user}@127.0.0.1" \
    bash --norc --noprofile -c \
    'count=0; until command -v rsync >/dev/null 2>&1; do if [ "$count" -ge '"$MAX_WAIT_COUNT"' ]; then echo "Error when trying to rsync files to kubernetes cluster. Package installation may have failed." >&2; exit 1; fi; sleep 0.5; count=$((count+1)); done; exec "$@"' \
    -- "$@"
