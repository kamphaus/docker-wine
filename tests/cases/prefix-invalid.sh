#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

out=$(run_cmd -e PREFIX_MODE=bogus "$img" true 2>&1) && fail "accepted PREFIX_MODE=bogus"
grep -q "invalid PREFIX_MODE 'bogus'; valid values: seed, ephemeral" <<<"$out" || fail "unexpected output: $out"

out=$(run_cmd -e PREFIX_UPGRADE=bogus "$img" true 2>&1) && fail "accepted PREFIX_UPGRADE=bogus"
grep -q "invalid PREFIX_UPGRADE 'bogus'; valid values: fail, reseed, keep" <<<"$out" || fail "unexpected output: $out"

# Plain docker-wine (no template) validates PREFIX_MODE too
out=$(run_cmd -e PREFIX_MODE=bogus "$IMAGE" true 2>&1) && fail "plain image accepted PREFIX_MODE=bogus"
grep -q "invalid PREFIX_MODE 'bogus'; valid values: seed, ephemeral" <<<"$out" || fail "unexpected plain-image output: $out"

# Plain docker-wine defaults to seed: Wine uses $HOME/.wine
out=$(run_cmd "$IMAGE" bash -c 'echo "$WINEPREFIX"' 2>/dev/null) \
    || fail "plain image start failed: $out"
[ "$out" = /home/wineuser/.wine ] || fail "plain image WINEPREFIX is '$out'"
pass
