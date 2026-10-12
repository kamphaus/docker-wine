#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

# A version string from the volume containing '/' is sanitised, reseed succeeds
vol=$(new_volume slash)
run_home "$vol" "$img" true 2>/dev/null || fail "first start failed"
"$RUNTIME" run --rm --user 123456:0 --entrypoint bash -v "$vol:/home/wineuser" "$img" \
    -c 'echo a/b > ~/.wine/.prefix-version' \
    || fail "could not write the a/b version"
out=$(run_home "$vol" -e PREFIX_UPGRADE=reseed "$img" bash -c 'cat ~/.wine/.prefix-version ~/.wine.bak-a_b/.prefix-version' 2>&1) \
    || fail "reseed with a/b version failed: $out"
[ "$(tail -n2 <<<"$out")" = $'1\na/b' ] || fail "unexpected reseed result: $out"

# $HOME/.wine that is a file fails clearly
vol2=$(new_volume file)
"$RUNTIME" run --rm --user 123456:0 --entrypoint bash -v "$vol2:/home/wineuser" "$img" -c 'echo x > ~/.wine' \
    || fail "could not create ~/.wine as a file"
out=$(run_home "$vol2" "$img" true 2>&1) && fail "started with a file as prefix"
grep -q "/home/wineuser/.wine is not a directory" <<<"$out" || fail "unexpected output: $out"
pass
