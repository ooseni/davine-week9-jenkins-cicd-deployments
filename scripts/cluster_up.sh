#!/usr/bin/env bash
# Create the Kubernetes cluster the pipeline deploys to, the way week 7 used minikube:
# k3d runs a one-node k3s cluster inside Docker, so Jenkins, the cluster and GitHub Actions can
# all use the same setup.
#
#   scripts/cluster_up.sh              cluster + namespace + deployer account + kubeconfigs
#   scripts/cluster_up.sh --registry   also a local registry on localhost:5050 (CI and rehearsals, no AWS)
#
# As cluster admin it applies k8s/cluster (the namespace, the jenkins-deployer account, the
# NetworkPolicies and the empty pull secret), then
# writes two kubeconfigs that hold only a 12-hour token for jenkins-deployer:
#   .live/deployer-kubeconfig   for this machine (API on 127.0.0.1:6550)
#   .live/jenkins-kubeconfig    for the Jenkins agent, which reaches the API by container name
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

K3S_IMAGE="rancher/k3s:v1.36.6-k3s1"
server="k3d-$CLUSTER-server-0"
registry_args=()
if [[ "${1:-}" == "--registry" ]]; then
    # The registry listens on localhost:5050 on this machine. Inside the cluster, "localhost" is
    # the node itself, so a mirror sends localhost:5050 to the registry's container instead: the
    # same image reference then works for `docker push` here and for the cluster's pulls.
    mkdir -p "$live_dir"
    printf 'mirrors:\n  "localhost:5050":\n    endpoint:\n      - http://davine-registry.localhost:5000\n' \
        >"$live_dir/registries.yaml"
    registry_args=(--registry-create "davine-registry.localhost:127.0.0.1:5050"
        --registry-config "$live_dir/registries.yaml")
fi

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
    log "cluster $CLUSTER already exists"
else
    log "creating cluster $CLUSTER ($K3S_IMAGE)"
    # NodePorts 30080 (rolling), 30081 (blue-green live) and 30082 (preview) are published on
    # this machine's loopback only. Traefik and metrics-server are not needed here.
    k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --servers 1 --agents 0 \
        --api-port 127.0.0.1:6550 \
        --port "127.0.0.1:30080-30082:30080-30082@server:0" \
        --k3s-arg "--disable=traefik@server:0" \
        --k3s-arg "--disable=metrics-server@server:0" \
        --k3s-arg "--tls-san=$server@server:0" \
        "${registry_args[@]}" --wait --timeout 180s
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null
kubectl wait --for=condition=Ready "node/$server" --timeout=120s

log "applying k8s/cluster as cluster admin: namespace $NAMESPACE (restricted pod security) and jenkins-deployer"
kubectl apply -k "$here/k8s/cluster"

mkdir -p "$live_dir"
token=$(kubectl -n "$NAMESPACE" create token jenkins-deployer --duration=12h)
ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
write_kubeconfig() { # write_kubeconfig FILE SERVER
    (
        umask 077
        cat >"$1" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER
    cluster:
      server: $2
      certificate-authority-data: $ca
users:
  - name: jenkins-deployer
    user:
      token: $token
contexts:
  - name: jenkins-deployer@$CLUSTER
    context:
      cluster: $CLUSTER
      user: jenkins-deployer
      namespace: $NAMESPACE
current-context: jenkins-deployer@$CLUSTER
EOF
    )
}
write_kubeconfig "$live_dir/deployer-kubeconfig" "https://127.0.0.1:6550"
write_kubeconfig "$live_dir/jenkins-kubeconfig" "https://$server:6443"
log "wrote .live/deployer-kubeconfig and .live/jenkins-kubeconfig (jenkins-deployer, valid 12 hours)"

section "What jenkins-deployer may do"
can() { KUBECONFIG="$live_dir/deployer-kubeconfig" kubectl auth can-i "$@" 2>/dev/null || true; }
check "patch deployments in $NAMESPACE" yes "$(can patch deployments -n "$NAMESPACE")"
check "create services in $NAMESPACE" yes "$(can create services -n "$NAMESPACE")"
check "list pods in $NAMESPACE" yes "$(can list pods -n "$NAMESPACE")"
check "delete deployments in $NAMESPACE" no "$(can delete deployments -n "$NAMESPACE")"
check "read secrets in kube-system" no "$(can get secrets -n kube-system)"
check "list nodes" no "$(can list nodes)"
check "delete namespace $NAMESPACE" no "$(can delete "namespace/$NAMESPACE")"
check "exec into pods" no "$(can create pods/exec -n "$NAMESPACE")"
check "change NetworkPolicies" no "$(can patch networkpolicies -n "$NAMESPACE")"
check "update the ecr-pull secret" yes "$(can update secret/ecr-pull -n "$NAMESPACE")"
check "read any other secret" no "$(can get secret/anything-else -n "$NAMESPACE")"
check "create secrets" no "$(can create secrets -n "$NAMESPACE")"
summary "cluster ready"
