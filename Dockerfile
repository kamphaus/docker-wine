# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-remote-desktop:resolute@sha256:b9fbacf659e29cb23f5389d4b16bb6f23f134402b154a7bb472a4bcf9e540ba0
FROM ${BASE_IMAGE}
USER 0

# renovate: datasource=deb depName=winehq-stable registryUrl=https://dl.winehq.org/wine-builds/ubuntu?suite=resolute&components=main&binaryArch=amd64 versioning=deb
ARG WINE_VERSION=11.0.0.0~resolute-1
COPY --chmod=0644 winehq-archive.asc /etc/apt/keyrings/winehq-archive.asc
# WineHQ's resolute builds use Wine's WoW64 mode: one amd64 package runs 32-bit and 64-bit Windows programs,
# so the image has no i386 (32-bit Linux) packages.
# ipp-usb (USB printer daemon, a Go binary) is only a Recommends of libsane1; it is useless in a
# container and its bundled Go stdlib carries CVEs, so never install it.
RUN printf '%s\n' 'Package: ipp-usb' 'Pin: release *' 'Pin-Priority: -1' > /etc/apt/preferences.d/no-ipp-usb \
 && printf '%s\n' 'Types: deb' 'URIs: https://dl.winehq.org/wine-builds/ubuntu' 'Suites: resolute' 'Components: main' \
      'Architectures: amd64' 'Signed-By: /etc/apt/keyrings/winehq-archive.asc' \
      > /etc/apt/sources.list.d/winehq.sources \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends \
      "winehq-stable=${WINE_VERSION}" "wine-stable=${WINE_VERSION}" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      7zip cabextract curl unzip winbind xauth xvfb \
 && rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-tags depName=Winetricks/winetricks
ARG WINETRICKS_VERSION=20260125
ARG WINETRICKS_COMMIT=b76e1ee79ac57d7aceb384f74518fc423265810c
ADD --chmod=0755 https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks /usr/local/bin/winetricks

COPY rootfs/ /
COPY addons.lock /tmp/addons.lock
RUN chmod 0755 /usr/local/bin/fetch-verified /usr/local/bin/wine-prefix \
 && chmod 0644 /etc/desktop/init.d/50-wine-prefix.sh \
 && fetch-verified /tmp/addons.lock /tmp/addons \
 && install -d /usr/share/wine/gecko /usr/share/wine/mono \
 && mv /tmp/addons/wine-gecko-* /usr/share/wine/gecko/ \
 && mv /tmp/addons/wine-mono-* /usr/share/wine/mono/ \
 && rm -rf /tmp/addons /tmp/addons.lock \
 && install -d -o 1001 -g 0 -m 0775 /opt/wine /run/wine-prefix \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
ENV WINEARCH=win64
# Override the label inherited from the base image so GHCR links this package to this repo
LABEL org.opencontainers.image.source="https://github.com/kamphaus/docker-wine"
USER 1001
