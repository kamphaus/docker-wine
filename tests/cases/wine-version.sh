#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
source "$REPO_ROOT/scripts/lib/wine-version.sh"

pkg=$(sed -n 's/^ARG WINE_VERSION=//p' "$REPO_ROOT/Dockerfile")
expected="wine-$(upstream_wine_version "$pkg")"
out=$(run_cmd "$IMAGE" wine --version)
[ "$out" = "$expected" ] || fail "wine --version is '$out', expected '$expected'"
pass "$out"
