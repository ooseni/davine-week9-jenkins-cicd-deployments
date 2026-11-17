#!/usr/bin/env bash
# Roll davine-webapp back to the revision that ran before the last deploy_rolling.sh, then verify
# that the previous release is the one answering.
#
#   scripts/rollback_rolling.sh
#
# It returns to the recorded revision number, not just "one back": if the failed deploy never
# created a new revision, `rollout undo` with no argument would go one release too far.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ -f "$STATE_DIR/previous-rolling.env" ]] || die "no deploy recorded in $STATE_DIR: nothing to roll back"
# shellcheck source=/dev/null
source "$STATE_DIR/previous-rolling.env"
[[ -n "${PREVIOUS_REVISION:-}" ]] || die "the failed deploy was the first release: there is no earlier one to return to"

log "rolling back davine-webapp to revision $PREVIOUS_REVISION ($PREVIOUS_VERSION)"
kc rollout undo deployment/davine-webapp --to-revision="$PREVIOUS_REVISION"
kc rollout status deployment/davine-webapp --timeout="$ROLLOUT_TIMEOUT"
kc rollout history deployment/davine-webapp | tail -n 4

now=$(kc get deployment davine-webapp -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$now" == "$PREVIOUS_IMAGE" ]] || die "after the rollback the image is $now, expected $PREVIOUS_IMAGE"
log "back on $PREVIOUS_IMAGE; verifying"
"$here/scripts/verify.sh" "$PREVIOUS_VERSION" "$PREVIOUS_IMAGE"
