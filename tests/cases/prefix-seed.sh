#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)
vol=$(new_volume seed)

out=$(run_home "$vol" "$img" bash -c 'echo "$WINEPREFIX"; cat "$WINEPREFIX/.prefix-version"' 2>/dev/null)
[ "$out" = $'/home/wineuser/.wine\n1' ] || fail "unexpected first start: $out"

out=$(run_home "$vol" "$img" true 2>&1)
! grep -q "copied template prefix" <<<"$out" || fail "prefix copied again on second start"

out=$(run_home "$vol" "$img" bash -c 'xvfb-run -a wine reg query "HKCU\\Software\\DesktopTest" /v Marker' 2>/dev/null)
grep -q fixture <<<"$out" || fail "template content missing from seeded prefix: $out"
pass
