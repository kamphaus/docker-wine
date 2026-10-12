#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

# A leftover partial copy is discarded and seeding completes
vol=$(new_volume partial)
"$RUNTIME" run --rm --user 123456:0 --entrypoint bash -v "$vol:/home/wineuser" "$img" \
    -c 'mkdir -p ~/.wine.partial && echo 1 > ~/.wine.partial/.prefix-version' \
    || fail "could not create a partial copy"
out=$(run_home "$vol" "$img" bash -c 'cat ~/.wine/.prefix-version; test ! -e ~/.wine.partial && echo clean' 2>/dev/null) \
    || fail "start with a partial copy failed: $out"
[ "$out" = $'1\nclean' ] || fail "partial copy not recovered: $out"

# A prefix owned by another uid (pre-migration winehome) fails with migration instructions
vol2=$(new_volume foreign)
"$RUNTIME" run --rm --user 0 --entrypoint bash -v "$vol2:/home/wineuser" "$img" \
    -c 'mkdir -p /home/wineuser/.wine && echo 1 > /home/wineuser/.wine/.prefix-version && chown -R 1010:1010 /home/wineuser/.wine' \
    || fail "could not create a foreign-owned prefix"
out=$(run_home "$vol2" "$img" true 2>&1) && fail "started with a foreign-owned prefix"
grep -q "/home/wineuser/.wine is owned by uid 1010" <<<"$out" || fail "unexpected output: $out"
grep -q "chown -R" <<<"$out" || fail "no migration hint: $out"
pass
