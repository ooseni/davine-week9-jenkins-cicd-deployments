#!/usr/bin/env bash
# End-to-end test of the deployment scripts the Jenkinsfile calls, on a real Kubernetes cluster,
# with no AWS. GitHub Actions runs it on every push; it also runs on a laptop.
#
#   scripts/cluster_up.sh --registry && tests/e2e.sh
#
# It builds two releases of the app (1.0.0 and 1.1.0), pushes them to the cluster's local
# registry, and then, acting as the jenkins-deployer account exactly as Jenkins does:
#   1. deploys 1.0.0 with a rolling update and verifies it;
#   2. rolls out 1.1.0 while a probe sends traffic, and expects no failed request;
#   3. deploys a bad release (ENV_MODE=prod), expects the rollout to fail with users still served
#      by 1.1.0, rolls back and verifies 1.1.0;
#   4-7. does the same with blue-green: first release, switch, instant switch back, and a bad
#      release that never reaches the live Service.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

# The local registry from `scripts/cluster_up.sh --registry`; the cluster reaches it by the same
# name through a mirror, as it reaches Amazon ECR in the live run.
REPO="${E2E_REGISTRY:-localhost:5050}/davine-webapp"
export KUBECONFIG="$live_dir/deployer-kubeconfig"
export STATE_DIR="$here/.deploy/e2e"
rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
[[ -f "$KUBECONFIG" ]] || die "run scripts/cluster_up.sh --registry first"

# expect CODE "what" COMMAND...: run a script, indent its output, and check its exit code.
expect() {
    local want=$1 what=$2 rc=0
    shift 2
    "$@" 2>&1 | sed 's/^/      /' || rc=${PIPESTATUS[0]}
    check "$what (exit code)" "$want" "$rc"
}
failed_requests() { awk '$2 != "200"' "$STATE_DIR/$1" | wc -l | tr -d ' '; }

section "Build and push two releases to $REPO"
build_push() { # build_push VERSION COMMIT: prints repository@digest, the way the pipeline deploys
    docker build -q --provenance=false --target runtime --build-arg "APP_VERSION=$1" --build-arg "GIT_COMMIT=$2" \
        -t "$REPO:$1" "$here/app" >/dev/null
    docker push -q "$REPO:$1" >/dev/null
    docker inspect --format '{{index .RepoDigests 0}}' "$REPO:$1"
}
v1=$(build_push 1.0.0 1111111)
v2=$(build_push 1.1.0 2222222)
log "1.0.0 is $v1"
log "1.1.0 is $v2"

section "1. Rolling: first release 1.0.0"
expect 0 "deploy 1.0.0" "$here/scripts/deploy_rolling.sh" "$v1"
expect 0 "verify 1.0.0" "$here/scripts/verify.sh" 1.0.0 "$v1"

section "2. Rolling: update to 1.1.0 under traffic"
expect 0 "deploy 1.1.0" "$here/scripts/deploy_rolling.sh" "$v2"
check "failed requests during the rolling update" 0 "$(failed_requests traffic-rolling.log)"
expect 0 "verify 1.1.0" "$here/scripts/verify.sh" 1.1.0 "$v2"

section "3. Rolling: bad release (ENV_MODE=prod), then rollback"
expect 1 "deploy the bad release fails" "$here/scripts/deploy_rolling.sh" "$v2" prod
check "failed requests while the bad release was stuck" 0 "$(failed_requests traffic-rolling.log)"
check "1.1.0 still answered during the bad release" yes \
    "$(awk '$3 == "1.1.0" { n++ } END { print (n > 0 ? "yes" : "no") }' "$STATE_DIR/traffic-rolling.log")"
expect 0 "rollback and verify 1.1.0" "$here/scripts/rollback_rolling.sh"
check "ENV_MODE after rollback" production \
    "$(kc get configmap "$(kc get deployment davine-webapp -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')" -o jsonpath='{.data.ENV_MODE}')"

section "4. Blue-green: first release 1.0.0"
expect 0 "deploy 1.0.0 to the idle slot and switch" "$here/scripts/blue_green.sh" deploy "$v1" 1.0.0
expect 0 "verify the live slot" "$here/scripts/verify.sh" --blue-green 1.0.0 "$v1"
first_live=$(kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}' || true)

section "5. Blue-green: switch to 1.1.0 under traffic"
expect 0 "deploy 1.1.0 to the idle slot and switch" "$here/scripts/blue_green.sh" deploy "$v2" 1.1.0
check "failed requests during the switch" 0 "$(failed_requests traffic-blue-green.log)"
check "live slot moved" yes "$([[ "$(kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}')" != "$first_live" ]] && echo yes || echo no)"
expect 0 "verify the live slot" "$here/scripts/verify.sh" --blue-green 1.1.0 "$v2"

section "6. Blue-green: instant rollback to 1.0.0"
expect 0 "switch back and verify 1.0.0" "$here/scripts/blue_green.sh" rollback
check "failed requests during the switch back" 0 "$(failed_requests traffic-blue-green-rollback.log)"
check "live slot is the first one again" "$first_live" "$(kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}')"

section "7. Blue-green: a bad release never reaches users"
expect 1 "deploy the bad release fails before the switch" "$here/scripts/blue_green.sh" deploy "$v2" 1.1.0 prod
check "live slot unchanged" "$first_live" "$(kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}')"
check "users still get" 1.0.0 "$(version_at "$BG_LIVE_URL")"
expect 0 "rollback cleans up the failed slot" "$here/scripts/blue_green.sh" rollback

section "8. NetworkPolicy: the app's pods cannot open outbound connections"
# As cluster admin: the deployer may not exec into pods. The same connection from a pod outside
# davine-space is the control, so the test cannot pass just because this network has no internet.
admin() { KUBECONFIG="${ADMIN_KUBECONFIG:-$HOME/.kube/config}" kubectl --context "k3d-$CLUSTER" "$@"; }
dial='import socket
try:
    socket.create_connection(("1.1.1.1", 443), timeout=5); print("OPEN")
except OSError as error:
    print("BLOCKED", type(error).__name__)'
control=$(admin -n default run egress-control --image="$v2" --restart=Never --rm -i --quiet \
    --command -- python -c "$dial" 2>&1 | grep -oE 'OPEN|BLOCKED' || true)
check "outbound from a pod outside davine-space (control)" OPEN "$control"
inside=$(admin -n "$NAMESPACE" exec deployment/davine-webapp -c app -- python -c "$dial" 2>&1 | grep -oE 'OPEN|BLOCKED' || true)
check "outbound from a davine-webapp pod" BLOCKED "$inside"

summary "end-to-end"
