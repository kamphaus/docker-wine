# syntax=docker/dockerfile:1
# Minimal derived image for the prefix tests: one registry key in the template prefix.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG PREFIX_VERSION
ENV PREFIX_VERSION=${PREFIX_VERSION}
RUN wine-prefix run -- wine reg add 'HKCU\Software\DesktopTest' /v Marker /d fixture /f \
 && wine-prefix finalize
