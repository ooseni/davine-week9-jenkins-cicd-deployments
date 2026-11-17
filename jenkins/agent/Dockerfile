# The build agent: Jenkins' inbound agent plus the tools the pipeline calls.
#   docker + buildx   build and push images through the host's Docker engine (socket mounted)
#   kubectl           deploy to the k3d cluster, as the jenkins-deployer account
#   curl, jq          the verify and traffic-probe scripts
FROM docker:29.9.3-cli@sha256:5a7af0dcb0e46c803efe9b45371dd21cb500e5b4453250394ac6f06d49b6e6f1 AS docker-cli

# checkov:skip=CKV_DOCKER_2:Jenkins monitors the agent over its WebSocket connection and marks it offline when it drops; a Docker health check would duplicate that.
FROM jenkins/inbound-agent:3395.v6e5377b_0fb_3c-5-jdk21@sha256:25a3704f7de4d3d0becc441f5683a227556658df1473865ee94c5232355678ab

USER 0:0
# Debian's security updates move these versions, so they follow the base image rather than a pin.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq \
 && rm -rf /var/lib/apt/lists/*

# The Docker CLI and buildx are static binaries, copied from Docker's own pinned image.
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

# kubectl, checked against the SHA-256 that dl.k8s.io publishes for this exact release.
ARG KUBECTL_VERSION=v1.36.6
ARG KUBECTL_SHA256=29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/kubectl

# Back to the image's jenkins user (UID and GID 1000) for the agent process.
USER 1000:1000
