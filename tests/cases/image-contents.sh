#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

# Packages that must never be in the image (unused daemons that drag in vulnerable code)
out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c 'for p in ipp-usb; do dpkg-query -W -f "\${Status} \${Package}\n" "$p" 2>/dev/null; done | grep "^install ok installed" || true')
[ -z "$out" ] || fail "forbidden packages installed: $out"

# The source label must point to this repository, not the base image's
src=$("$RUNTIME" image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$IMAGE")
[ "$src" = https://github.com/kamphaus/docker-wine ] || fail "org.opencontainers.image.source is '$src'"
pass
