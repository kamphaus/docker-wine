#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

# Packages that must never be in the image (unused daemons that drag in vulnerable code)
out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c 'for p in ipp-usb; do dpkg-query -W -f "\${Status} \${Package}\n" "$p" 2>/dev/null; done | grep "^install ok installed" || true')
[ -z "$out" ] || fail "forbidden packages installed: $out"
pass
