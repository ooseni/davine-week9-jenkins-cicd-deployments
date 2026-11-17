#!/usr/bin/env bash
# Tests the Jenkins controller image and the Jenkinsfile, with no AWS and no cluster:
#   - the image builds and Configuration as Code loads with no error;
#   - security: anonymous users get nothing, the controller runs no builds;
#   - the agent node, the pipeline job (pointing at this repository's Jenkinsfile) and both
#     credentials exist, and every pinned plugin is active;
#   - Jenkins' own declarative linter accepts the Jenkinsfile, and rejects a broken copy of it.
# Run: bash tests/test_jenkins.sh   (GitHub Actions runs it on every push)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/scripts/lib.sh"

name=davine-wk9-jenkins-test
port=18080
url="http://127.0.0.1:$port"
work=$(mktemp -d)
# -v: the Jenkins image declares /var/jenkins_home a volume; without it every run leaves ~250 MB behind.
cleanup() { docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# Dummy secrets, readable by the jenkins user whatever this machine's user ID is.
password=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
printf '%s' "$password" >"$work/jenkins_admin_password"
printf '%s' "not-a-real-token" >"$work/ecr_token"
printf 'apiVersion: v1\nkind: Config\nclusters: []\n' >"$work/kubeconfig"
chmod 0755 "$work" && chmod 0644 "$work"/*

section "Build and start the controller"
docker build -q -t davine-wk9-jenkins-controller:test "$here/jenkins/controller" >/dev/null
docker run -d --name "$name" -p "127.0.0.1:$port:8080" \
    -e ECR_REPOSITORY_URL=123456789012.dkr.ecr.us-east-1.amazonaws.com/davine-wk9-webapp \
    -v "$work:/run/secrets:ro" davine-wk9-jenkins-controller:test >/dev/null
for _ in $(seq 90); do
    [[ "$(http_code "$url/login")" == 200 ]] && break
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]]; then
        echo "      Jenkins stopped while starting. The errors in its log:"
        docker logs "$name" 2>&1 | grep -E 'SEVERE|Exception:' | head -5 | sed 's/^/      /'
        break
    fi
    sleep 2
done
check "Jenkins answers" 200 "$(http_code "$url/login")"
sleep 5 # let Configuration as Code finish creating the job
check "Configuration as Code loaded without errors" 0 \
    "$(docker logs "$name" 2>&1 | grep -cE 'ConfiguratorException|Failed to load|SEVERE' || true)"

# --globoff: the [...] in Jenkins tree= queries is not a curl URL pattern
api() { curl -sfg -m 10 -u "admin:$password" "$url$1" || true; } # gitleaks:allow (random test password)

section "Security"
check "anonymous request is refused" 403 "$(http_code "$url/api/json")"
check "admin can sign in" 200 "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -u "admin:$password" "$url/api/json")"
check "wrong password is refused" 401 "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -u "admin:wrong" "$url/api/json")"
check "built-in node executors" 0 "$(api '/computer/(built-in)/api/json' | jq '.numExecutors')"
check "TCP agent port" -1 "$(api '/api/json?tree=slaveAgentPort' | jq '.slaveAgentPort // -1')"

section "Agent, job, credentials and plugins"
agent=$(api '/computer/docker-agent/api/json')
check "agent docker-agent exists with label docker" yes \
    "$(jq -r '[.assignedLabels[].name] | index("docker") != null | if . then "yes" else "no" end' <<<"$agent")"
check "agent executors" 1 "$(jq '.numExecutors' <<<"$agent")"
job=$(api '/job/davine-webapp/config.xml')
check "job reads Jenkinsfile from main of this repository" yes "$(grep -q '<scriptPath>Jenkinsfile</scriptPath>' <<<"$job" &&
    grep -q 'github.com/ooseni/davine-week9-jenkins-cicd-deployments.git' <<<"$job" &&
    grep -q '<name>\*/main</name>' <<<"$job" && echo yes || echo no)"
# The job must poll from the moment the controller starts, not only after its first build.
check "job polls GitHub every 2 minutes from start-up" yes "$(grep -q '<spec>H/2 \* \* \* \*</spec>' <<<"$job" &&
    grep -q 'hudson.triggers.SCMTrigger' <<<"$job" && echo yes || echo no)"
creds=$(api '/credentials/store/system/domain/_/api/json?tree=credentials[id]' | jq -r '[.credentials[].id] | sort | join(",")')
check "credentials" "ecr-registry,k3d-deployer-kubeconfig" "$creds"
check "ECR repository passed in as a global variable" yes \
    "$(docker exec "$name" grep -q 'ECR_REPOSITORY_URL' /var/jenkins_home/config.xml && echo yes || echo no)"
plugins=$(api '/pluginManager/api/json?tree=plugins[shortName,active]')
check "plugins installed" "$(grep -cE '^[a-z0-9-]+:' "$here/jenkins/controller/plugins.txt")" "$(jq '.plugins | length' <<<"$plugins")"
check "plugins not active" 0 "$(jq '[.plugins[] | select(.active | not)] | length' <<<"$plugins")"

section "Jenkinsfile, checked by Jenkins' declarative linter"
jar="$work/cookies"
crumb=$(curl -sf -c "$jar" -u "admin:$password" "$url/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb')
lint() { curl -s -b "$jar" -u "admin:$password" -H "$crumb" -X POST -F "jenkinsfile=<$1" "$url/pipeline-model-converter/validate"; }
result=$(lint "$here/Jenkinsfile")
echo "      $result"
check "Jenkinsfile" "Jenkinsfile successfully validated." "$result"
sed 's/stage(.Verify.) {/stage("Verify") { bogus true/' "$here/Jenkinsfile" >"$work/Jenkinsfile.broken"
check "a broken copy is rejected" yes "$(lint "$work/Jenkinsfile.broken" | grep -q 'Errors encountered' && echo yes || echo no)"

summary "Jenkins controller and Jenkinsfile"
