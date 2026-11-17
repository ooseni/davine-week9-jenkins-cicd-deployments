#!/usr/bin/env bash
# Verify that a release is live: the app answers through its Service, reports the expected
# version in /version and /metrics, no pod of another release still answers, and every pod runs
# the image the pipeline pushed.
#
#   scripts/verify.sh [--blue-green] EXPECTED_VERSION [EXPECTED_IMAGE]
#
# Default target: the rolling Deployment davine-webapp behind NodePort 30080.
# --blue-green: whichever slot the live Service points at, behind NodePort 30081.
# VERIFY_URL, VERIFY_DEPLOYMENT, VERIFY_SELECTOR and VERIFY_TARGET (environment) override the
# target; blue_green.sh uses them to test the idle slot through the preview Service.
# EXPECTED_IMAGE is optional; when given, the Deployment and every pod must use exactly that reference.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

url=$APP_URL deployment=davine-webapp selector=app=davine-webapp target="rolling Deployment"
if [[ "${1:-}" == "--blue-green" ]]; then
    shift
    slot=$(kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}')
    url=$BG_LIVE_URL deployment=davine-webapp-$slot selector="app=davine-webapp-bg,slot=$slot"
    target="blue-green live slot ($slot)"
fi
url=${VERIFY_URL:-$url}
deployment=${VERIFY_DEPLOYMENT:-$deployment}
selector=${VERIFY_SELECTOR:-$selector}
target=${VERIFY_TARGET:-$target}
version=${1:?usage: verify.sh [--blue-green] EXPECTED_VERSION [EXPECTED_IMAGE]}
image=${2:-}

section "Verify $version on the $target at $url"
# A Service catches up with pod changes a moment after Kubernetes reports them, so first wait
# (up to 60 s) for ten answers in a row from the expected release. Users are not affected by this
# lag: the traffic probe during each change measures that separately.
settled=no started=$SECONDS streak=0
while (( SECONDS - started < 60 )); do
    if [[ "$(version_at "$url")" == "$version" ]]; then streak=$((streak + 1)); else streak=0; fi
    if (( streak >= 10 )); then settled=yes; break; fi
    sleep 0.5
done
check "Service gives 10 answers in a row from $version (within 60 s)" yes "$settled"
check "GET /healthz" 200 "$(http_code "$url/healthz")"
check "GET /readyz" 200 "$(http_code "$url/readyz")"
check "/version reports" "$version" "$(version_at "$url")"
build_info=$(curl -sf -m 5 "$url/metrics" | grep -o '^davine_webapp_build_info{version="[^"]*"' | cut -d'"' -f2 || true)
check "/metrics build_info version" "$version" "$build_info"

# Thirty requests, each on a new connection: every one must come from the expected release.
answers=$(for _ in $(seq 30); do version_at "$url"; echo; done | sed '/^$/d' | sort | uniq -c | awk '{printf "%s%s x%s", (n++ ? ", " : ""), $2, $1}')
check "30 requests answered by" "$version x30" "$answers"

# What Kubernetes says, not only what the app says.
read -r desired ready updated < <(kc get deployment "$deployment" \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas}{"\n"}')
check "$deployment ready replicas" "$desired" "${ready:-0}"
check "$deployment updated replicas" "$desired" "${updated:-0}"
if [[ -n "$image" ]]; then
    check "$deployment image" "$image" \
        "$(kc get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    # With a digest in the pod spec, the runtime can only start content with that digest. (The
    # imageID the runtime reports is not used: for identical content pushed twice it names the
    # first digest it stored.)
    pods=$(kc get pods -l "$selector" -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null)
        | "\(.metadata.name) \(.spec.containers[0].image)"')
    while read -r pod pod_image; do
        [[ -n "$pod" ]] || continue
        check "pod $pod image" "$image" "$pod_image"
    done <<<"$pods"
fi
summary "verify $version"
