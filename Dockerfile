# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-remote-desktop:noble
FROM ${BASE_IMAGE}
USER 0

# renovate: datasource=deb depName=winehq-stable registryUrl=https://dl.winehq.org/wine-builds/ubuntu?suite=noble&components=main&binaryArch=amd64 versioning=deb
ARG WINE_VERSION=11.0.0.0~noble-1
COPY --chmod=0644 winehq-archive.asc /etc/apt/keyrings/winehq-archive.asc
RUN dpkg --add-architecture i386 \
 && printf '%s\n' 'Types: deb' 'URIs: https://dl.winehq.org/wine-builds/ubuntu' 'Suites: noble' 'Components: main' \
      'Architectures: amd64 i386' 'Signed-By: /etc/apt/keyrings/winehq-archive.asc' \
      > /etc/apt/sources.list.d/winehq.sources \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends \
      "winehq-stable=${WINE_VERSION}" "wine-stable=${WINE_VERSION}" \
      "wine-stable-amd64=${WINE_VERSION}" "wine-stable-i386:i386=${WINE_VERSION}" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      cabextract curl p7zip unzip winbind xauth xvfb \
 && rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-tags depName=Winetricks/winetricks
ARG WINETRICKS_VERSION=20260125
ARG WINETRICKS_COMMIT=b76e1ee79ac57d7aceb384f74518fc423265810c
ADD --chmod=0755 --checksum=sha256:431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks /usr/local/bin/winetricks

COPY rootfs/ /
COPY addons.lock /tmp/addons.lock
RUN chmod 0755 /usr/local/bin/fetch-verified \
 && fetch-verified /tmp/addons.lock /tmp/addons \
 && install -d /usr/share/wine/gecko /usr/share/wine/mono \
 && mv /tmp/addons/wine-gecko-* /usr/share/wine/gecko/ \
 && mv /tmp/addons/wine-mono-* /usr/share/wine/mono/ \
 && rm -rf /tmp/addons /tmp/addons.lock \
 && install -d -o 1001 -g 0 -m 0775 /opt/wine /run/wine-prefix \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
ENV WINEARCH=win64
USER 1001
