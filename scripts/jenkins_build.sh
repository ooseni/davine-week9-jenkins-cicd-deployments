#!/usr/bin/env bash
# Start a build of the davine-webapp job, or follow one that polling started, and save its console.
#
#   scripts/jenkins_build.sh [STRATEGY] [SIMULATE_BAD_RELEASE]   start a build, e.g. rolling false
#   scripts/jenkins_build.sh --follow NUMBER                     follow build NUMBER
#
# Streams the console as it runs, saves it to .live/jenkins-build-NUMBER.txt, and exits 0 only
# if the build succeeded. Uses the admin password from .live/jenkins-admin-password.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

jenkins="http://127.0.0.1:8080"
job="$jenkins/job/davine-webapp"
auth="admin:$(cat "$live_dir/jenkins-admin-password")"
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT
crumb=$(curl -sf -c "$jar" -u "$auth" "$jenkins/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb')
post() { curl -sf -b "$jar" -u "$auth" -H "$crumb" -X POST -D - -o /dev/null "$@"; }

if [[ "${1:-}" == "--follow" ]]; then
    number=${2:?usage: jenkins_build.sh --follow NUMBER}
else
    strategy=${1:-rolling}
    bad=${2:-false}
    # A job's parameters exist only after its first run has read the Jenkinsfile.
    if curl -sfg -u "$auth" "$job/api/json?tree=property[parameterDefinitions[name]]" | grep -q STRATEGY; then
        headers=$(post "$job/buildWithParameters" --data-urlencode "STRATEGY=$strategy" \
            --data-urlencode "SIMULATE_BAD_RELEASE=$bad")
    else
        log "first build: the job learns its parameters from the Jenkinsfile, so it runs with the defaults"
        headers=$(post "$job/build")
    fi
    queue=$(sed -n 's/^[Ll]ocation: *\(.*queue\/item\/[0-9]*\/\).*/\1/p' <<<"$headers" | tr -d '\r')
    [[ -n "$queue" ]] || die "Jenkins did not queue the build"
    number=""
    for _ in $(seq 120); do
        number=$(curl -sf -u "$auth" "${queue}api/json" | jq -r '.executable.number // empty')
        [[ -n "$number" ]] && break
        sleep 2
    done
    [[ -n "$number" ]] || die "the build did not leave the queue"
    log "started build #$number (STRATEGY=$strategy, SIMULATE_BAD_RELEASE=$bad)"
fi

# Stream the console with Jenkins' progressive text API until the build ends. That API keeps
# Jenkins' hidden console annotations (ESC[8mha:...ESC[0m), which are removed for the terminal.
chunk="$jar.chunk"
start=0
while :; do
    headers=$(curl -s -u "$auth" -D - -o "$chunk" "$job/$number/logText/progressiveText?start=$start")
    sed -E $'s/\e\\[8mha:[^\e]*\e\\[0m//g' "$chunk"
    start=$(sed -n 's/^[Xx]-[Tt]ext-[Ss]ize: *\([0-9]*\).*/\1/p' <<<"$headers" | tr -d '\r')
    grep -qi '^x-more-data: *true' <<<"$headers" || break
    sleep 2
done
rm -f "$chunk"
sleep 1
# The saved copy comes from /consoleText, which Jenkins serves without the annotations.
out="$live_dir/jenkins-build-$number.txt"
curl -sf -u "$auth" "$job/$number/consoleText" >"$out"
result=$(curl -sf -u "$auth" "$job/$number/api/json" | jq -r .result)
log "build #$number finished: $result (console saved to .live/jenkins-build-$number.txt)"
[[ "$result" == SUCCESS ]]
