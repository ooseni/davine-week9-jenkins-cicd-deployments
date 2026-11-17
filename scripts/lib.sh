#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source it; do not run it.
#
# The same scripts run in three places: on the Jenkins agent (the pipeline), in GitHub Actions
# (tests/e2e.sh) and on a laptop. Only the addresses differ, and they come from the environment.
# shellcheck shell=bash

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034 # used by the scripts that source this file
live_dir="$here/.live"                   # git-ignored: tokens, kubeconfigs, raw transcripts
STATE_DIR="${STATE_DIR:-$here/.deploy}"  # git-ignored: what each deploy replaced, traffic logs
export LC_ALL=C AWS_PAGER=""

CLUSTER="${CLUSTER:-davine-wk9}"
NAMESPACE="${NAMESPACE:-davine-space}"
# Where the cluster's NodePorts answer: localhost on a laptop or a CI runner, the k3d node's
# container name on the Jenkins agent, which shares the cluster's Docker network.
NODE_HOST="${DAVINE_NODE_HOST:-localhost}"
APP_URL="${APP_URL:-http://$NODE_HOST:30080}"
BG_LIVE_URL="${BG_LIVE_URL:-http://$NODE_HOST:30081}"
BG_PREVIEW_URL="${BG_PREVIEW_URL:-http://$NODE_HOST:30082}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
kc() { kubectl -n "$NAMESPACE" "$@"; }

# --- PASS/FAIL bookkeeping, as in the week 4 scripts ---------------------------------------------
passed=0
failed=0
section() { printf '\n== %s\n' "$1"; }
# check "what is being checked" EXPECTED ACTUAL
check() {
    if [[ "$3" == "$2" ]]; then
        printf '  PASS  %s: %s\n' "$1" "$3"; passed=$((passed + 1))
    else
        printf '  FAIL  %s: got "%s", wanted "%s"\n' "$1" "$3" "$2"; failed=$((failed + 1))
    fi
}
summary() {
    printf '\n== %s: %d passed, %d failed\n' "$1" "$passed" "$failed"
    [[ "$failed" -eq 0 ]]
}

# --- HTTP ---------------------------------------------------------------------------------------
# http_code URL: the status code, or 000 when nothing answers within 5 seconds
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" || true; }
# json_field URL FIELD: one top-level string field of a JSON response, empty on any failure
json_field() { curl -sf -m 5 "$1" 2>/dev/null | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null || true; }
version_at() { json_field "$1/version" version; }

# --- Traffic probe: proves whether users saw errors during a deploy -----------------------------
# probe_start LOGFILE URL: request URL/version about ten times a second in the background, one line
# per request: time, status code, version that answered. A new connection each time, so requests
# spread over all pods behind the Service.
probe_start() {
    probe_log=$1
    local url=$2
    : >"$probe_log"
    (
        trap 'exit 0' TERM
        while :; do
            out=$(curl -s -m 2 -w '\n%{http_code}' "$url/version" 2>/dev/null || true)
            code=${out##*$'\n'}
            version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' <<<"${out%$'\n'*}")
            printf '%s %s %s\n' "$(date -u +%H:%M:%S.%3N)" "${code:-000}" "${version:--}" >>"$probe_log"
            sleep 0.1
        done
    ) &
    probe_pid=$!
}
# probe_stop: stop the probe and print what users saw. Sets PROBE_TOTAL and PROBE_FAILED.
probe_stop() {
    [[ -n "${probe_pid:-}" ]] || return 0
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
    probe_pid=""
    PROBE_TOTAL=$(wc -l <"$probe_log" | tr -d ' ')
    PROBE_FAILED=$(awk '$2 != "200"' "$probe_log" | wc -l | tr -d ' ')
    local served
    served=$(awk '$2 == "200" { n[$3]++ } END { for (v in n) printf "%s%s x%d", (s++ ? ", " : ""), v, n[v] }' "$probe_log")
    log "traffic during the change: $PROBE_TOTAL requests, $PROBE_FAILED failed; answered by ${served:-nothing}"
}

# --- Registry pull secret -----------------------------------------------------------------------
# With REGISTRY_SERVER, REGISTRY_USERNAME and REGISTRY_PASSWORD set (the pipeline passes its ECR
# token), store them as the ecr-pull secret the pods name. The password goes through a private
# temporary file, never a command-line argument that other processes could read.
ensure_pull_secret() {
    if [[ -z "${REGISTRY_SERVER:-}" || -z "${REGISTRY_PASSWORD:-}" ]]; then
        log "no registry credentials given: the cluster pulls without a secret"
        return 0
    fi
    local tmp auth
    tmp=$(umask 077 && mktemp)
    auth=$(printf '%s:%s' "${REGISTRY_USERNAME:-AWS}" "$REGISTRY_PASSWORD" | base64 | tr -d '\n')
    jq -n --arg s "$REGISTRY_SERVER" --arg a "$auth" '{auths: {($s): {auth: $a}}}' >"$tmp"
    kc create secret generic ecr-pull --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="$tmp" --dry-run=client -o yaml | kc apply -f - >/dev/null
    rm -f "$tmp"
    log "pull secret ecr-pull refreshed for $REGISTRY_SERVER"
}

# --- Waiting for a rollout ----------------------------------------------------------------------
# wait_for_rollout DEPLOYMENT SELECTOR: 0 when the rollout completes, 1 when it cannot.
# Kubernetes counts image pulls against progressDeadlineSeconds, and the first pull of a new base
# image from ECR took 1 min 39 s on this connection, so the deadline is a generous 180 s. A release
# that is really broken is caught sooner: as soon as one of its pods crash-loops (2 restarts) or
# cannot get its image, the wait stops and the pipeline can roll back.
wait_for_rollout() {
    local deployment=$1 selector=$2 started=$SECONDS out last="" broken
    local limit=${ROLLOUT_TIMEOUT_SECONDS:-300}
    while ((SECONDS - started < limit)); do
        if ! out=$(kc rollout status "deployment/$deployment" --watch=false 2>&1); then
            echo "$out" # for example: exceeded its progress deadline
            return 1
        fi
        [[ "$out" != "$last" ]] && echo "$out" && last=$out
        [[ "$out" == *"successfully rolled out"* ]] && return 0
        broken=$(kc get pods -l "$selector" -o json | jq -r '.items[] | .metadata.name as $pod
            | .status.containerStatuses[]? | (.state.waiting.reason // "") as $why
            | select(($why == "CrashLoopBackOff" and .restartCount >= 2)
                or ($why | test("^(ImagePullBackOff|InvalidImageName|CreateContainerConfigError)$")))
            | "\($pod) is in \($why) after \(.restartCount) restarts"' | head -1)
        if [[ -n "$broken" ]]; then
            log "failing fast: $broken"
            return 1
        fi
        sleep 3
    done
    log "the rollout did not finish within $limit s"
    return 1
}

# --- Why a rollout is stuck ---------------------------------------------------------------------
# explain_rollout DEPLOYMENT SELECTOR: the pods, the Deployment's conditions and the last log
# lines of a pod that is not ready. This is what turns "rollout failed" into a cause in the console.
explain_rollout() {
    local deployment=$1 selector=$2 pod
    log "pods of $deployment:"
    kc get pods -l "$selector" -o wide --no-headers 2>&1 | sed 's/^/    /'
    log "conditions of $deployment:"
    kc get deployment "$deployment" \
        -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.reason}: {.message}{"\n"}{end}'
    pod=$(kc get pods -l "$selector" -o json | jq -r '
        [.items[] | select(any(.status.containerStatuses[]?; .ready == false))] | first | .metadata.name // empty')
    if [[ -n "$pod" ]]; then
        # A crash-looping container is usually between restarts: its last run's log is "previous".
        local lines
        lines=$(kc logs "$pod" --tail=5 --previous 2>/dev/null || kc logs "$pod" --tail=5 2>/dev/null || true)
        log "last log lines of $pod, which is not ready:"
        printf '%s\n' "${lines:-(no log lines yet)}" | sed 's/^/    /'
        log "recent events of $pod (an image still downloading shows here):"
        kc get events --field-selector "involvedObject.name=$pod" --sort-by=.lastTimestamp \
            -o custom-columns=AGE:.lastTimestamp,REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null |
            tail -n 3 | sed 's/^/    /'
    fi
}

# --- Redaction for transcripts that go into docs/evidence -----------------------------------------
# The account ID becomes <ACCOUNT_ID>, the session name (the signed-in person) and the IAM
# Identity Center permission-set suffix become placeholders; role names stay readable. Public
# addresses become <PUBLIC_IP>. Docker's own private addresses become <PRIVATE_IP>. 127.0.0.1 and
# 0.0.0.0 stay readable. An account ID is 12 digits with no letter or digit on either side, so the
# tail of a hex digest or resource ID is left alone. The pattern consumes the character after the
# match, so it runs twice to catch a second match that shares it ("id,id").
redact() {
    local account='s/(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)/\1<ACCOUNT_ID>\2/g'
    local public='s/(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)/\1<PUBLIC_IP>\2/g'
    # This machine's home directory (it holds the local user name) becomes ~.
    local home='s#^$##'
    if [[ "${HOME:-/}" != / ]]; then home="s#${HOME//#/\\#}#~#g"; fi
    sed -u -E -e "$home" -e "$account" -e "$account" \
        -e "s#(assumed-role/[^/ ]+)/[^ \"]+#\1/<SESSION>#g" \
        -e "s#(AWSReservedSSO_)[A-Za-z0-9_]+#\1<PERMISSION_SET>#g" \
        -e "s/0\.0\.0\.0/__ANY4__/g; s/127\.0\.0\.1/__LOOPBACK__/g" \
        -e "s/(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}/\1<PRIVATE_IP>/g" \
        -e "$public" -e "$public" \
        -e "s/__ANY4__/0.0.0.0/g; s/__LOOPBACK__/127.0.0.1/g"
}
