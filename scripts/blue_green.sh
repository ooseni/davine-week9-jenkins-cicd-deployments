#!/usr/bin/env bash
# Blue-green deployment of davine-webapp (manifests in k8s/blue-green).
#
#   scripts/blue_green.sh deploy IMAGE_REF EXPECTED_VERSION [ENV_MODE]
#   scripts/blue_green.sh rollback
#   scripts/blue_green.sh status
#
# deploy    puts the release on the idle slot, waits for it to be ready, verifies it through the
#           preview Service, and only then points the live Service at it. A release that never
#           becomes ready, or fails verification, is never seen by users. The old slot keeps
#           running, so going back is one selector change.
# rollback  points the live Service back at the slot that was live before the last deploy, if it
#           moved, and scales the failed slot to zero.
# status    which slot is live, and what each slot runs.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPLICAS=${BG_REPLICAS:-2}
state="$STATE_DIR/previous-bg.env"

other() { if [[ "$1" == blue ]]; then echo green; else echo blue; fi; }
live_slot() { kc get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}'; }
ready_in() { # ready pods in a slot; Kubernetes leaves the field out when there are none
    local ready
    ready=$(kc get deployment "davine-webapp-$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    echo "${ready:-0}"
}
point() { # point SERVICE SLOT
    kc patch service "$1" --type merge -p "{\"spec\":{\"selector\":{\"app\":\"davine-webapp-bg\",\"slot\":\"$2\"}}}" >/dev/null
}

# render_idle_overlay DIR IMAGE ENV_MODE IDLE LIVE FIRST: a one-off overlay on top of
# k8s/blue-green holding only what this release changes: the idle slot's Deployment (image,
# replicas, change-cause) and its ConfigMap. `$patch: delete` drops the live slot, so
# `kubectl apply` cannot touch what users are on. The Services are created by the first release
# only; after that their selectors are runtime state, changed by the switch.
render_idle_overlay() {
    local dir=$1 image=$2 env_mode=$3 idle=$4 live=$5 first=$6 name pin api kind
    if [[ "$image" == *@sha256:* ]]; then
        name=${image%@*} pin="digest: ${image#*@}"
    else
        name=${image%:*} pin="newTag: ${image##*:}"
    fi
    cat >"$dir/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NAMESPACE
resources:
  - $(realpath --relative-to="$dir" "$here/k8s/blue-green")
images:
  - name: davine-webapp
    newName: $name
    $pin
configMapGenerator:
  - name: web-config-bg
    behavior: merge
    literals:
      - ENV_MODE=$env_mode
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: davine-webapp-$idle
        namespace: $NAMESPACE
        annotations:
          kubernetes.io/change-cause: $(jq -Rn --arg c "${CHANGE_CAUSE:-deploy $image}" '$c')
      spec:
        replicas: $REPLICAS
YAML
    if [[ "$first" == no ]]; then
        local kind_name
        for kind_name in "apps/v1 Deployment davine-webapp-$live" "v1 Service davine-webapp-bg-live" \
            "v1 Service davine-webapp-bg-preview"; do
            read -r api kind name <<<"$kind_name"
            # shellcheck disable=SC2016 # $patch is kustomize syntax, written literally
            printf '  - patch: |-\n      $patch: delete\n      apiVersion: %s\n      kind: %s\n      metadata:\n        name: %s\n        namespace: %s\n' \
                "$api" "$kind" "$name" "$NAMESPACE" >>"$dir/kustomization.yaml"
        done
    fi
}

deploy() {
    local image=${1:?usage: blue_green.sh deploy IMAGE_REF EXPECTED_VERSION [ENV_MODE]}
    local version=${2:?usage: blue_green.sh deploy IMAGE_REF EXPECTED_VERSION [ENV_MODE]}
    local env_mode=${3:-production}
    [[ "$image" =~ ^[a-z0-9.:/_-]+(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$ ]] || die "not an image reference: $image"
    [[ "$env_mode" =~ ^[A-Za-z0-9._-]+$ ]] || die "ENV_MODE may only hold letters, digits, dot, dash, underscore"
    mkdir -p "$STATE_DIR"
    ensure_pull_secret

    local live idle first=no live_version=""
    if kc get service davine-webapp-bg-live >/dev/null 2>&1; then
        live=$(live_slot)
    else
        first=yes live=blue # the selector k8s/blue-green/services.yaml starts with
    fi
    idle=$(other "$live")
    if [[ "$first" == no && "$(ready_in "$live")" -gt 0 ]]; then live_version=$(version_at "$BG_LIVE_URL"); fi
    printf 'BG_PREVIOUS_LIVE=%q\nBG_TARGET=%q\nPREVIOUS_VERSION=%q\n' "$live" "$idle" "$live_version" >"$state"
    log "live slot: $live (${live_version:-no release yet}); deploying $version to the idle slot: $idle"

    # 1. Release onto the idle slot. Users are still on the live slot and see nothing of this.
    overlay=$(mktemp -d)
    trap 'probe_stop >/dev/null 2>&1 || true; rm -rf "$overlay"' EXIT
    render_idle_overlay "$overlay" "$image" "$env_mode" "$idle" "$live" "$first"
    kubectl apply -k "$overlay"
    [[ "$first" == yes ]] || point davine-webapp-bg-preview "$idle"
    if ! kc rollout status "deployment/davine-webapp-$idle" --timeout="$ROLLOUT_TIMEOUT"; then
        explain_rollout "davine-webapp-$idle" "app=davine-webapp-bg,slot=$idle"
        die "the $idle slot never became ready, so the switch was not made: users stayed on $live"
    fi

    # 2. Test it where users cannot see it.
    if ! VERIFY_URL=$BG_PREVIEW_URL VERIFY_DEPLOYMENT=davine-webapp-$idle \
        VERIFY_SELECTOR="app=davine-webapp-bg,slot=$idle" \
        VERIFY_TARGET="idle $idle slot, through the preview Service" \
        "$here/scripts/verify.sh" "$version" "$image"; then
        die "the $idle slot failed verification, so the switch was not made: users stayed on $live"
    fi

    # 3. Switch. One API call moves every new connection to the new slot.
    if [[ -n "$live_version" ]]; then probe_start "$STATE_DIR/traffic-blue-green.log" "$BG_LIVE_URL"; fi
    log "switching live from $live to $idle"
    point davine-webapp-bg-live "$idle"
    point davine-webapp-bg-preview "$live"
    if [[ -n "$live_version" ]]; then
        sleep 5
        probe_stop
        [[ "$PROBE_FAILED" -eq 0 ]] || die "users saw $PROBE_FAILED failed requests during the switch"
    fi
    if [[ -n "$live_version" ]]; then
        log "live is now $idle ($version). $live keeps $(ready_in "$live") ready pods of $live_version for an instant rollback"
    else
        log "live is now $idle ($version). This was the first release, so there is nothing to roll back to yet"
    fi
}

rollback() {
    [[ -f "$state" ]] || die "no blue-green deploy recorded in $STATE_DIR: nothing to roll back"
    # shellcheck source=/dev/null
    source "$state"
    local live
    live=$(live_slot)
    if [[ "$live" != "$BG_PREVIOUS_LIVE" ]]; then
        [[ "$(ready_in "$BG_PREVIOUS_LIVE")" -gt 0 ]] ||
            die "the $BG_PREVIOUS_LIVE slot has no ready pods to switch back to"
        probe_start "$STATE_DIR/traffic-blue-green-rollback.log" "$BG_LIVE_URL"
        log "switching live back from $live to $BG_PREVIOUS_LIVE"
        point davine-webapp-bg-live "$BG_PREVIOUS_LIVE"
        point davine-webapp-bg-preview "$BG_TARGET"
        sleep 5
        probe_stop
    else
        log "live never left $BG_PREVIOUS_LIVE: users were not affected by the failed release"
    fi
    log "scaling the failed $BG_TARGET slot to 0"
    kc scale "deployment/davine-webapp-$BG_TARGET" --replicas=0 >/dev/null
    if [[ -n "$PREVIOUS_VERSION" ]]; then
        "$here/scripts/verify.sh" --blue-green "$PREVIOUS_VERSION"
    else
        log "there was no earlier release on the live slot to verify"
    fi
}

status() {
    local live slot
    live=$(live_slot)
    for slot in blue green; do
        printf '%-6s %-8s ready %s/%s  %s\n' "$slot" "$([[ $slot == "$live" ]] && echo LIVE || echo standby)" \
            "$(ready_in "$slot")" "$(kc get deployment "davine-webapp-$slot" -o jsonpath='{.spec.replicas}')" \
            "$(kc get deployment "davine-webapp-$slot" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    done
}

case "${1:-}" in
    deploy) shift; deploy "$@" ;;
    rollback) rollback ;;
    status) status ;;
    *) die "usage: blue_green.sh deploy IMAGE_REF EXPECTED_VERSION [ENV_MODE] | rollback | status" ;;
esac
