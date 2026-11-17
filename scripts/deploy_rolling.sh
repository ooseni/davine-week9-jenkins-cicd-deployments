#!/usr/bin/env bash
# Rolling deploy of one image to the davine-webapp Deployment, with a traffic probe running the
# whole time to show whether any user request failed.
#
#   scripts/deploy_rolling.sh IMAGE_REF [ENV_MODE]
#
# IMAGE_REF  repository@sha256:<digest> (what the pipeline passes) or repository:tag
# ENV_MODE   production unless given. The pipeline's bad-release rehearsal passes "prod", a typo
#            the app refuses to start with.
# CHANGE_CAUSE (environment) is recorded on the Deployment and shows in `kubectl rollout history`.
#
# Before applying, it records the running release in $STATE_DIR/previous-rolling.env for
# rollback_rolling.sh. Exit 0 when the rollout completed and at most 1% of the probe's requests
# failed (MAX_FAILED_PERCENT).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

image=${1:?usage: deploy_rolling.sh IMAGE_REF [ENV_MODE]}
env_mode=${2:-production}
cause=${CHANGE_CAUSE:-"deploy $image with ENV_MODE=$env_mode"}
# These values are written into YAML below, so only plain image references and words get through.
[[ "$image" =~ ^[a-z0-9.:/_-]+(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$ ]] || die "not an image reference: $image"
[[ "$env_mode" =~ ^[A-Za-z0-9._-]+$ ]] || die "ENV_MODE may only hold letters, digits, dot, dash, underscore"
mkdir -p "$STATE_DIR"

# 1. Record what runs now, so a rollback knows exactly where to return.
previous_image=$(kc get deployment davine-webapp -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
previous_revision=$(kc get deployment davine-webapp \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)
previous_version=$(version_at "$APP_URL")
{
    printf 'PREVIOUS_IMAGE=%q\n' "$previous_image"
    printf 'PREVIOUS_REVISION=%q\n' "$previous_revision"
    printf 'PREVIOUS_VERSION=%q\n' "$previous_version"
} >"$STATE_DIR/previous-rolling.env"
log "running now: ${previous_version:-nothing} (revision ${previous_revision:-none}, ${previous_image:-no Deployment yet})"

ensure_pull_secret

# 2. A one-off overlay on top of k8s/rolling: this release's image, ENV_MODE and change-cause.
overlay=$(mktemp -d)
trap 'probe_stop >/dev/null 2>&1 || true; rm -rf "$overlay"' EXIT
if [[ "$image" == *@sha256:* ]]; then
    name=${image%@*} pin="digest: ${image#*@}"
else
    name=${image%:*} pin="newTag: ${image##*:}"
fi
cat >"$overlay/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NAMESPACE
resources:
  - $(realpath --relative-to="$overlay" "$here/k8s/rolling")
images:
  - name: davine-webapp
    newName: $name
    $pin
configMapGenerator:
  - name: web-config
    behavior: merge
    literals:
      - ENV_MODE=$env_mode
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: davine-webapp
        namespace: $NAMESPACE
        annotations:
          kubernetes.io/change-cause: $(jq -Rn --arg c "$cause" '$c')
EOF

# 3. Apply and watch. With maxUnavailable 0 the old pods keep serving until each new one is ready.
if [[ -n "$previous_version" ]]; then
    probe_start "$STATE_DIR/traffic-rolling.log" "$APP_URL"
fi
log "applying $image with ENV_MODE=$env_mode"
kubectl apply -k "$overlay"
rc=0
if ! wait_for_rollout davine-webapp app=davine-webapp; then
    rc=1
    log "the rollout did not complete; finding out why"
    explain_rollout davine-webapp app=davine-webapp
fi
if [[ -n "$previous_version" ]]; then
    sleep 3 # keep probing a moment after the last old pod has gone
    probe_stop
    probe_within_budget || rc=1
fi
kc rollout history deployment/davine-webapp | tail -n 4
exit "$rc"
