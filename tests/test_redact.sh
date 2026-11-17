#!/usr/bin/env bash
# Tests for redact() in scripts/lib.sh, which cleans every transcript before it goes into
# docs/evidence: no account ID, signed-in user, permission set, home directory or IP address may
# get through, and image digests, versions and timestamps must stay exactly as they were.
# Run: bash tests/test_redact.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source <(sed -n '/^redact()/,/^}/p' "$here/scripts/lib.sh")
HOME=/home/someone

failures=0
expect() {
    local input=$1 want=$2 got
    got=$(redact <<<"$input")
    if [[ "$got" == "$want" ]]; then
        echo "  PASS  $want"
    else
        echo "  FAIL  $input -> $got (wanted $want)"; failures=$((failures + 1))
    fi
}
# Account IDs, wherever AWS puts them
expect "arn:aws:iam::123456789012:role/davine-wk9-jenkins-ecr-push" "arn:aws:iam::<ACCOUNT_ID>:role/davine-wk9-jenkins-ecr-push"
expect "123456789012.dkr.ecr.us-east-1.amazonaws.com/davine-wk9-webapp:1.0.0-1c07371-b2" "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/davine-wk9-webapp:1.0.0-1c07371-b2"
expect '"registryId": "123456789012",' '"registryId": "<ACCOUNT_ID>",'
expect "owners 123456789012,123456789012" "owners <ACCOUNT_ID>,<ACCOUNT_ID>"
# The signed-in identity
expect "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_0abc123/someone x" "arn:aws:sts::<ACCOUNT_ID>:assumed-role/AWSReservedSSO_<PERMISSION_SET>/<SESSION> x"
expect "role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_0abc123" "role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_<PERMISSION_SET>"
expect "assumed-role/davine-wk9-jenkins-ecr-push/jenkins-ecr-1763362000" "assumed-role/davine-wk9-jenkins-ecr-push/<SESSION>"
# This machine
# shellcheck disable=SC2088 # the literal ~ is the expected output, not a path to expand
expect "/home/someone/projects/wk9/.live/ecr-token" "~/projects/wk9/.live/ecr-token"
expect "/home/jenkins/agent/workspace/davine-webapp" "/home/jenkins/agent/workspace/davine-webapp"
# Addresses
expect "dial tcp 10.42.0.13:8080 and gateway 172.22.0.1" "dial tcp <PRIVATE_IP>:8080 and gateway <PRIVATE_IP>"
expect "from 52.94.236.248,3.5.1.9 now" "from <PUBLIC_IP>,<PUBLIC_IP> now"
expect "http://127.0.0.1:8080/ 0.0.0.0/0 127.0.0.1:30080" "http://127.0.0.1:8080/ 0.0.0.0/0 127.0.0.1:30080"
# Things that must not change
expect "sha256:4e4829ae3d06692d5ef23a17dfdfd52924c5f045b11e8a76da0a59da0be4dff8" "sha256:4e4829ae3d06692d5ef23a17dfdfd52924c5f045b11e8a76da0a59da0be4dff8"
expect "sha256:ab123456789012cd" "sha256:ab123456789012cd"
expect "epoch-ms 1763362000123 stays" "epoch-ms 1763362000123 stays"
expect "Jenkins 2.580.2, k3s v1.36.6-k3s1, kubectl v1.36.6, release 1.1.0" "Jenkins 2.580.2, k3s v1.36.6-k3s1, kubectl v1.36.6, release 1.1.0"
expect "[2026-11-17T07:03:41.236Z] 07:03:41.236 200 1.0.0" "[2026-11-17T07:03:41.236Z] 07:03:41.236 200 1.0.0"
echo "== redact: $failures failures"
[[ "$failures" -eq 0 ]]
