# syntax=docker/dockerfile:1
# RDP client for tests/k8s/kind-e2e.sh (FreeRDP under Xvfb), reusing the base image's pinned apt snapshot.
# Stays on the noble (Ubuntu 24.04) base although docker-wine uses resolute: 26.04 has no freerdp2-x11
# (only freerdp3-x11), the noble digest stays pullable, and the client does not affect the image under test.
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-remote-desktop:noble@sha256:18304a93eb4325e28c4045788e84e41ee87ff806eef4c8ba827ad58f03ac8b6f
FROM ${BASE_IMAGE}
USER 0
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends freerdp2-x11 xauth xvfb \
 && rm -rf /var/lib/apt/lists/*
USER 1001
ENTRYPOINT []
