#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

out=$(run_cmd -e PREFIX_MODE=ephemeral -v /run/wine-prefix "$img" bash -c \
    'echo "$WINEPREFIX"; cat "$WINEPREFIX/.prefix-version"; readlink "$WINEPREFIX/drive_c/users/wineuser/Documents"' 2>/dev/null) \
    || fail "ephemeral start failed: $out"
[ "$out" = $'/run/wine-prefix/prefix\n1\n/home/wineuser/Documents' ] || fail "unexpected ephemeral prefix: $out"

out=$(run_cmd -e PREFIX_MODE=ephemeral "$img" true 2>&1) && fail "ephemeral mode started without a writable /run/wine-prefix"
grep -q "/run/wine-prefix is not writable" <<<"$out" || fail "unexpected output: $out"
# Plain docker-wine (no template): ephemeral mode gives an empty, uid-owned prefix that Wine initialises
out=$(run_cmd -e PREFIX_MODE=ephemeral -v /run/wine-prefix "$IMAGE" bash -c \
    'echo "$WINEPREFIX"; ls -A "$WINEPREFIX" | wc -l; xvfb-run -a wine cmd /c ver 2>/dev/null' 2>/dev/null) \
    || fail "plain image ephemeral start failed: $out"
[ "$(sed -n 1p <<<"$out")" = /run/wine-prefix/prefix ] || fail "plain image ephemeral WINEPREFIX: $out"
[ "$(sed -n 2p <<<"$out")" = 0 ] || fail "plain image ephemeral prefix not empty at start: $out"
grep -q "Microsoft Windows" <<<"$out" || fail "Wine did not initialise the plain ephemeral prefix: $out"
pass
