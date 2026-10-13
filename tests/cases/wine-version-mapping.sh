#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
source "$REPO_ROOT/scripts/lib/wine-version.sh"

check() { [ "$(upstream_wine_version "$1")" = "$2" ] || fail "$1 -> $(upstream_wine_version "$1"), expected $2"; }
check '11.0.0.0~noble-1' 11.0
check '10.0.0.0~noble-1' 10.0
check '10.0.1.0~noble-1' 10.0.1
check '10.17.0.0~noble-1' 10.17
check '11.0.0.0~resolute-1' 11.0
pass
