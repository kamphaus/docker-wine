# syntax=docker/dockerfile:1
# Example derived image: Notepad++ pre-installed in the template prefix.
# Bump PREFIX_VERSION whenever the installed software changes (for example when downloads.lock is updated);
# existing seed-mode prefixes then require PREFIX_UPGRADE=reseed or keep.
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-wine:stable@sha256:e26b3c16126896d11c405c81892b334ab787b4193c5f8fbd4a09bdc565d38ae6
FROM ${BASE_IMAGE}
ENV PREFIX_VERSION=notepadpp-8.9.8.1-1
RUN --mount=type=bind,source=downloads.lock,target=/tmp/downloads.lock \
    fetch-verified /tmp/downloads.lock /tmp/dl \
 && wine-prefix run -- wine /tmp/dl/npp-installer.exe /S \
 && wine-prefix finalize \
 && rm -rf /tmp/dl
COPY --chmod=0755 notepadpp /usr/local/bin/notepadpp
COPY --chmod=0644 notepadpp.desktop /etc/xdg/autostart/notepadpp.desktop
