#!/usr/bin/env bash
# Start Jenkins (controller + agent, jenkins/compose.yaml) for the pipeline.
#
#   scripts/jenkins_up.sh           Amazon ECR: mint a 12-hour registry token through the
#                                   push-only IAM role from terraform/, and give Jenkins only that
#   scripts/jenkins_up.sh --local   the local registry on localhost:5050, no AWS at all
#                                   (needs `scripts/cluster_up.sh --registry`)
#
# Run it again to refresh the token: it rewrites the secret and restarts the controller.
# Needs scripts/cluster_up.sh first (the agent deploys with .live/jenkins-kubeconfig), and for
# the default mode an AWS session (AWS_PROFILE) that the push role trusts.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

compose_file="$here/jenkins/compose.yaml"
jenkins="http://127.0.0.1:8080"
[[ -f "$live_dir/jenkins-kubeconfig" ]] || die "run scripts/cluster_up.sh first"
umask 077

section "1. Registry credentials"
if [[ "${1:-}" == "--local" ]]; then
    ECR_REPOSITORY_URL="localhost:5050/davine-webapp"
    printf '%s' "local-registry-needs-no-token" >"$live_dir/ecr-token"
    log "local mode: images go to $ECR_REPOSITORY_URL; no AWS involved"
else
    tf() { terraform -chdir="$here/terraform" output -raw "$1"; }
    ECR_REPOSITORY_URL=$(tf repository_url)
    role=$(tf push_role_arn)
    region=$(tf region)
    log "assuming the push-only role $(redact <<<"$role")"
    creds=$(aws sts assume-role --role-arn "$role" --role-session-name "jenkins-ecr-$(date +%s)" \
        --duration-seconds 3600 --query Credentials --output json)
    as_role() {
        env -u AWS_PROFILE AWS_REGION="$region" \
            AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")" \
            AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")" \
            AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")" "$@"
    }
    log "token requested as: $(as_role aws sts get-caller-identity --query Arn --output text | redact)"
    auth=$(as_role aws ecr get-authorization-token --query 'authorizationData[0]' --output json)
    # The token is base64 of "AWS:<password>". Only the password is stored, in a private file.
    jq -r .authorizationToken <<<"$auth" | base64 -d | cut -d: -f2- | tr -d '\n' >"$live_dir/ecr-token"
    log "ECR token stored in .live/ecr-token; ECR says it expires at $(jq -r .expiresAt <<<"$auth")"
    unset creds auth
fi

section "2. Jenkins admin password"
if [[ ! -s "$live_dir/jenkins-admin-password" ]]; then
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24 >"$live_dir/jenkins-admin-password"
    log "generated a random admin password in .live/jenkins-admin-password"
else
    log "keeping the admin password in .live/jenkins-admin-password"
fi
password=$(cat "$live_dir/jenkins-admin-password")

export ECR_REPOSITORY_URL
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
export DOCKER_GID
export JENKINS_AGENT_SECRET="${JENKINS_AGENT_SECRET:-pending}" # replaced in step 4
# JENKINS_COMPOSE_EXTRA (optional): one more compose file layered on top, for example to mount a
# local copy of the repository for a rehearsal before pushing to GitHub.
compose() { docker compose -f "$compose_file" ${JENKINS_COMPOSE_EXTRA:+-f "$JENKINS_COMPOSE_EXTRA"} "$@"; }

section "3. Controller"
if [[ -n "$(compose ps -q controller 2>/dev/null)" ]]; then
    log "controller running: restarting it so Configuration as Code reads the new token"
    compose up -d --build --force-recreate controller
else
    compose up -d --build controller
fi
for _ in $(seq 120); do
    [[ "$(http_code "$jenkins/login")" == 200 ]] && break
    sleep 2
done
check "Jenkins answers on $jenkins" 200 "$(http_code "$jenkins/login")"

section "4. Agent"
# Jenkins derives each inbound agent's secret from its own key; read it with the admin account.
JENKINS_AGENT_SECRET=$(curl -sf -u "admin:$password" "$jenkins/computer/docker-agent/jenkins-agent.jnlp" |
    sed -n 's:.*<application-desc><argument>\([0-9a-f]\{64\}\)</argument>.*:\1:p')
[[ -n "$JENKINS_AGENT_SECRET" ]] || die "could not read the agent secret from Jenkins"
export JENKINS_AGENT_SECRET
compose --profile agent up -d --build --force-recreate agent
online=no
for _ in $(seq 60); do
    if [[ "$(curl -sf -u "admin:$password" "$jenkins/computer/docker-agent/api/json" | jq -r .offline)" == false ]]; then
        online=yes
        break
    fi
    sleep 2
done
check "agent docker-agent online" yes "$online"
summary "Jenkins up"
log "open $jenkins and sign in as admin; the password is in .live/jenkins-admin-password"
