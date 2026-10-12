#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
v1=$(fixture_image 1)
v2=$(fixture_image 2)
vol=$(new_volume upgrade)
run_home "$vol" "$v1" true 2>/dev/null || fail "first start with version 1 failed"

out=$(run_home "$vol" "$v2" true 2>&1) && fail "started with a mismatched prefix version"
grep -q "prefix version 1 does not match image version 2; set PREFIX_UPGRADE=reseed or keep" <<<"$out" \
    || fail "unexpected output: $out"

out=$(run_home "$vol" -e PREFIX_UPGRADE=keep "$v2" cat /home/wineuser/.wine/.prefix-version 2>&1) \
    || fail "PREFIX_UPGRADE=keep failed: $out"
grep -q "WARNING: keeping prefix version 1" <<<"$out" || fail "keep did not warn: $out"
[ "$(tail -n1 <<<"$out")" = 1 ] || fail "keep replaced the prefix: $out"

out=$(run_home "$vol" -e PREFIX_UPGRADE=reseed "$v2" bash -c 'cat ~/.wine/.prefix-version ~/.wine.bak-1/.prefix-version' 2>/dev/null) \
    || fail "PREFIX_UPGRADE=reseed failed: $out"
[ "$out" = $'2\n1' ] || fail "reseed result: $out"
pass
