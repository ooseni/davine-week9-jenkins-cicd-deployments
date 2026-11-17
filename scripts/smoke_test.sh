#!/usr/bin/env bash
# Smoke test of a freshly built image, before it is pushed anywhere:
#   - it starts with a valid setting, as the non-root user, on a read-only filesystem with no
#     Linux capabilities, and Docker's health check turns healthy;
#   - /version reports the version and commit it was built with;
#   - with a mistyped ENV_MODE it refuses to start (exit code 3). That is the behaviour the
#     rolling update relies on to stop a bad release.
#
#   scripts/smoke_test.sh IMAGE EXPECTED_VERSION EXPECTED_COMMIT
#
# The checks run inside the container with `docker exec`, so the script needs no network path
# between the Jenkins agent and the container.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

image=${1:?usage: smoke_test.sh IMAGE EXPECTED_VERSION EXPECTED_COMMIT}
version=${2:?usage: smoke_test.sh IMAGE EXPECTED_VERSION EXPECTED_COMMIT}
commit=${3:?usage: smoke_test.sh IMAGE EXPECTED_VERSION EXPECTED_COMMIT}
name="smoke-$$-$RANDOM"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

section "Smoke test $image"
docker run -d --name "$name" -e ENV_MODE=production --read-only --cap-drop ALL \
    --security-opt no-new-privileges "$image" >/dev/null
health=starting
for _ in $(seq 30); do
    health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
    [[ "$health" == starting ]] || break
    sleep 1
done
check "Docker health check" healthy "$health"
check "runs as user" 10001:10001 "$(docker inspect -f '{{.Config.User}}' "$name")"
get() { docker exec "$name" python -c "import sys, urllib.request as u; print(u.urlopen('http://127.0.0.1:8080' + sys.argv[1], timeout=3).read().decode())" "$1"; }
release=$(get /version)
check "/version version" "$version" "$(jq -r .version <<<"$release")"
check "/version commit" "$commit" "$(jq -r .commit <<<"$release")"
check "/readyz status" ready "$(get /readyz | jq -r .status)"
docker rm -f "$name" >/dev/null

set +e
refusal=$(docker run --rm -e ENV_MODE=prod --read-only "$image" 2>&1)
code=$?
set -e
check "exit code with ENV_MODE=prod" 3 "$code"
check "says why it refused" yes "$(grep -q 'refusing to start: ENV_MODE' <<<"$refusal" && echo yes || echo no)"
summary "smoke test"
