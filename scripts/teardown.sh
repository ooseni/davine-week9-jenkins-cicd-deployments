#!/usr/bin/env bash
# Remove everything the lab created, then search for anything left behind.
#
#   scripts/teardown.sh | tee .live/teardown.txt    (then redact into docs/evidence)
#
# Order: Jenkins (containers and its volume), the k3d cluster and registry, the AWS resources
# with terraform destroy, then a search by name and by tag in AWS, and of local Docker objects.
# The secret files in .live/ (ECR token, kubeconfigs, Jenkins password) are deleted last.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

section "1. Jenkins"
ECR_REPOSITORY_URL=unused JENKINS_AGENT_SECRET=unused DOCKER_GID=0 \
    docker compose -f "$here/jenkins/compose.yaml" --profile agent down --volumes --remove-orphans 2>&1 | sed 's/^/    /'

section "2. Kubernetes cluster"
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
    k3d cluster delete "$CLUSTER" 2>&1 | grep -E 'Deleting|Successfully' | sed 's/^/    /'
fi
docker rm -f davine-registry.localhost >/dev/null 2>&1 || true

section "3. AWS (terraform destroy)"
if [[ -f "$here/terraform/terraform.tfstate" ]] && [[ -n "$(terraform -chdir="$here/terraform" state list 2>/dev/null)" ]]; then
    terraform -chdir="$here/terraform" destroy -auto-approve -no-color 2>&1 |
        grep -E 'Destroying|Destruction complete|Destroy complete|Error' | sed 's/^/    /' | redact
else
    log "no Terraform state with resources: nothing to destroy"
fi

section "4. Anything left?"
AWS_REGION=${AWS_REGION:-us-east-1}
export AWS_REGION
# The backticks are JMESPath string literals for the AWS CLI, not shell expansions.
# shellcheck disable=SC2016
repos_query='length(repositories[?starts_with(repositoryName, `davine-wk9`)])'
# shellcheck disable=SC2016
roles_query='length(Roles[?starts_with(RoleName, `davine-wk9`)])'
check "ECR repositories named davine-wk9*" 0 "$(aws ecr describe-repositories --query "$repos_query" --output text)"
check "IAM roles named davine-wk9*" 0 "$(aws iam list-roles --query "$roles_query" --output text)"
check "resources tagged with this project" 0 \
    "$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=davine-week9-jenkins-cicd-deployments \
        --query 'length(ResourceTagMappingList)' --output text)"
check "k3d clusters named $CLUSTER" 0 "$(k3d cluster list -o json | jq --arg c "$CLUSTER" '[.[] | select(.name == $c)] | length')"
check "Jenkins containers" 0 "$(docker ps -a --filter name=davine-wk9-jenkins -q | grep -c . || true)"
check "Jenkins volume" 0 "$(docker volume ls -q --filter name=davine-wk9-jenkins | grep -c . || true)"

section "5. Local secrets and images"
rm -f "$live_dir"/{ecr-token,jenkins-admin-password,jenkins-kubeconfig,deployer-kubeconfig}
check "secret files left in .live" 0 \
    "$(find "$live_dir" -maxdepth 1 \( -name ecr-token -o -name jenkins-admin-password -o -name '*kubeconfig' \) | grep -c . || true)"
docker image ls --format '{{.Repository}}:{{.Tag}}' |
    grep -E '(^|/)(davine-webapp|davine-wk9-[a-z-]+)(:|$)' | xargs -r docker image rm >/dev/null 2>&1 || true
check "lab images left in Docker" 0 \
    "$(docker image ls --format '{{.Repository}}' | grep -cE '(^|/)(davine-webapp|davine-wk9-)' || true)"
summary "teardown"
