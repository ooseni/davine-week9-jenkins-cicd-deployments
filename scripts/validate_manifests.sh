#!/usr/bin/env bash
# Render every kustomization in k8s/ and validate the result against the Kubernetes 1.36 API
# schemas with kubeconform, in strict mode (unknown fields are errors). Needs kubectl and Docker.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e"

for dir in cluster rolling blue-green; do
    printf 'k8s/%-11s ' "$dir"
    kubectl kustomize "$here/k8s/$dir" |
        docker run --rm -i "$KUBECONFORM_IMAGE" -strict -summary -kubernetes-version 1.36.0 -
done
