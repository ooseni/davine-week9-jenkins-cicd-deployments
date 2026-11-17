#!/usr/bin/env bash
# Live verification after the Jenkins builds: Amazon ECR, the push role, the cluster and Jenkins.
#
#   scripts/verify_live.sh | tee .live/verify-live.txt    (then redact into docs/evidence)
#
# Read-only, except for two writes that are expected to be refused: moving an existing tag to
# another image (immutability) and deleting an image as the push role (least privilege).
# Needs the AWS session (AWS_PROFILE), terraform outputs, the k3d admin context and Jenkins.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

tf() { terraform -chdir="$here/terraform" output -raw "$1"; }
repo=$(tf repository_name)
role=$(tf push_role_arn)
AWS_REGION=$(tf region)
export AWS_REGION
admin() { kubectl --context "k3d-$CLUSTER" -n "$NAMESPACE" "$@"; }
jenkins="http://127.0.0.1:8080/job/davine-webapp"
jauth="admin:$(cat "$live_dir/jenkins-admin-password")"

section "Amazon ECR repository $repo"
r=$(aws ecr describe-repositories --repository-names "$repo" --query 'repositories[0]' --output json)
check "tag mutability" IMMUTABLE "$(jq -r .imageTagMutability <<<"$r")"
check "scan on push" true "$(jq -r .imageScanningConfiguration.scanOnPush <<<"$r")"
check "encryption" KMS "$(jq -r .encryptionConfiguration.encryptionType <<<"$r")"
lifecycle=$(aws ecr get-lifecycle-policy --repository-name "$repo" --query lifecyclePolicyText --output text)
check "lifecycle rules" 2 "$(jq '.rules | length' <<<"$lifecycle")"

section "Images pushed by Jenkins"
images=$(aws ecr describe-images --repository-name "$repo" --output json |
    jq -c '.imageDetails | sort_by(.imagePushedAt)[]')
printf '  %-28s %-19s %-9s %s\n' TAG DIGEST SIZE_MB SCAN
while read -r image; do
    printf '  %-28s %-19s %-9s %s\n' "$(jq -r '.imageTags[0] // "-"' <<<"$image")" \
        "$(jq -r '.imageDigest[0:19]' <<<"$image")" \
        "$(jq -r '(.imageSizeInBytes / 1048576 * 10 | floor) / 10' <<<"$image")" \
        "$(jq -r '(.imageScanStatus.status // "-") + " " + ((.imageScanFindingsSummary.findingSeverityCounts // {}) | to_entries | map("\(.key)=\(.value)") | join(","))' <<<"$image")"
done <<<"$images"
count=$(grep -c . <<<"$images")
check "every image has a unique tag" "$count" "$(jq -r '.imageTags[0]' <<<"$images" | sort -u | grep -c .)"
check "scans completed" "$count" "$(jq -r 'select(.imageScanStatus.status == "COMPLETE") | .imageDigest' <<<"$images" | grep -c . || true)"

section "Immutability: moving an existing tag to another image is refused"
first_tag=$(jq -r '.imageTags[0]' <<<"$images" | head -1)
last_digest=$(jq -r '.imageDigest' <<<"$images" | tail -1)
manifest=$(aws ecr batch-get-image --repository-name "$repo" --image-ids "imageDigest=$last_digest" \
    --query 'images[0].imageManifest' --output text)
moved=$(aws ecr put-image --repository-name "$repo" --image-tag "$first_tag" --image-manifest "$manifest" 2>&1 || true)
check "retag $first_tag to the newest image" ImageTagAlreadyExistsException \
    "$(grep -oE 'ImageTagAlreadyExistsException' <<<"$moved" | head -1)"

section "The push role Jenkins' token comes from"
creds=$(aws sts assume-role --role-arn "$role" --role-session-name "verify-$(date +%s)" --query Credentials --output json)
as_role() {
    env -u AWS_PROFILE AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")" \
        AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")" \
        AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")" "$@" 2>&1
}
outcome() { if grep -qE 'AccessDenied|not authorized' <<<"$1"; then echo denied; else echo allowed; fi; }
log "acting as $(as_role aws sts get-caller-identity --query Arn --output text | redact)"
check "get a registry token" allowed "$(outcome "$(as_role aws ecr get-authorization-token --query 'authorizationData[0].expiresAt' --output text)")"
check "pull an image manifest" allowed "$(outcome "$(as_role aws ecr batch-get-image --repository-name "$repo" --image-ids "imageDigest=$last_digest" --query 'images[0].imageId.imageDigest' --output text)")"
check "list repositories" denied "$(outcome "$(as_role aws ecr describe-repositories --output text)")"
check "delete an image" denied "$(outcome "$(as_role aws ecr batch-delete-image --repository-name "$repo" --image-ids "imageDigest=$last_digest")")"
check "create a repository" denied "$(outcome "$(as_role aws ecr create-repository --repository-name davine-wk9-should-not-exist)")"
check "list S3 buckets" denied "$(outcome "$(as_role aws s3api list-buckets --output text)")"
unset creds

section "IAM policy simulation of the push role"
other="${role%%:role/*}"
other="arn:aws:ecr:$AWS_REGION:${other##*::}:repository/some-other-repository"
repo_arn=$(jq -r .repositoryArn <<<"$r")
sim() { aws iam simulate-principal-policy --policy-source-arn "$role" --action-names "$1" \
    --resource-arns "$2" --query 'EvaluationResults[0].EvalDecision' --output text; }
check "ecr:PutImage on $repo" allowed "$(sim ecr:PutImage "$repo_arn")"
check "ecr:PutImage on another repository" implicitDeny "$(sim ecr:PutImage "$other")"
check "ecr:BatchDeleteImage on $repo" implicitDeny "$(sim ecr:BatchDeleteImage "$repo_arn")"
check "ecr:SetRepositoryPolicy on $repo" implicitDeny "$(sim ecr:SetRepositoryPolicy "$repo_arn")"
check "iam:CreateAccessKey" implicitDeny "$(sim iam:CreateAccessKey '*')"

section "Kubernetes: what is running"
live_image=$(admin get deployment davine-webapp -o jsonpath='{.spec.template.spec.containers[0].image}')
log "davine-webapp runs $(redact <<<"$live_image")"
check "rolling Deployment image comes from ECR by digest" yes \
    "$([[ "$live_image" == *".dkr.ecr.$AWS_REGION.amazonaws.com/$repo@sha256:"* ]] && echo yes || echo no)"
check "that digest is in ECR" "${live_image#*@}" \
    "$(jq -r --arg d "${live_image#*@}" 'select(.imageDigest == $d) | .imageDigest' <<<"$images")"
check "pull secret is for the ECR registry" yes \
    "$(admin get secret ecr-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[0]' |
        grep -q "\.dkr\.ecr\.$AWS_REGION\.amazonaws\.com$" && echo yes || echo no)"
echo "  Rollout history of davine-webapp:"
admin rollout history deployment/davine-webapp | sed '1,2d; s/^/    /' | redact
live_slot=$(admin get service davine-webapp-bg-live -o jsonpath='{.spec.selector.slot}' 2>/dev/null || true)
if [[ -n "$live_slot" ]]; then
    echo "  Blue-green slots (live: $live_slot):"
    for slot in blue green; do
        printf '    %-6s ready %s/%s  %s\n' "$slot" \
            "$(admin get deployment "davine-webapp-$slot" -o jsonpath='{.status.readyReplicas}' | sed 's/^$/0/')" \
            "$(admin get deployment "davine-webapp-$slot" -o jsonpath='{.spec.replicas}')" \
            "$(admin get deployment "davine-webapp-$slot" -o jsonpath='{.spec.template.spec.containers[0].image}' | redact)"
    done
fi
echo "  What the app says:"
printf '    rolling    (NodePort 30080): %s\n' "$(curl -s -m 5 "$APP_URL/version")"
printf '    blue-green (NodePort 30081): %s\n' "$(curl -s -m 5 "$BG_LIVE_URL/version")"

section "Jenkins builds"
curl -sf -u "$jauth" "$jenkins/api/json?tree=builds%5Bnumber,result,displayName,description,duration,timestamp%5D" |
    jq -r '.builds | sort_by(.number)[] | "  #\(.number)  \(.result)  \(.displayName | sub("^#[0-9]+ "; ""))  \(.description // "")  \((.duration / 1000 | floor))s  started \(.timestamp / 1000 | strftime("%H:%M:%SZ"))"'
check "builds that failed only after rolling back" "$(curl -sf -u "$jauth" "$jenkins/api/json?tree=builds%5Bresult,description%5D" |
    jq '[.builds[] | select(.result == "FAILURE")] | length')" \
    "$(curl -sf -u "$jauth" "$jenkins/api/json?tree=builds%5Bresult,description%5D" |
        jq '[.builds[] | select(.result == "FAILURE" and ((.description // "") | test("rolled back")))] | length')"
summary "live verification"
