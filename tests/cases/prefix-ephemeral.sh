#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

out=$(run_cmd -e PREFIX_MODE=ephemeral -v /run/wine-prefix "$img" bash -c \
    'echo "$WINEPREFIX"; cat "$WINEPREFIX/.prefix-version"; readlink "$WINEPREFIX/drive_c/users/wineuser/Documents"' 2>/dev/null)
[ "$out" = $'/run/wine-prefix/prefix\n1\n/home/wineuser/Documents' ] || fail "unexpected ephemeral prefix: $out"

out=$(run_cmd -e PREFIX_MODE=ephemeral "$img" true 2>&1) && fail "ephemeral mode started without a writable /run/wine-prefix"
grep -q "/run/wine-prefix is not writable" <<<"$out" || fail "unexpected output: $out"
pass
