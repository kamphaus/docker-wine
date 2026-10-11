#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

# Wine 11 installs Gecko (any version: the MSI layout has no version directory) to
# <windows>/{system32,syswow64}/gecko/plugin and Mono to <windows>/mono/mono-2.0.
gecko=$(awk '$1 ~ /^wine-gecko/ {print $2; exit}' "$REPO_ROOT/addons.lock")
run_cmd "$IMAGE" bash -c '
    p=$WINEPREFIX
    xvfb-run -a wineboot -i >/dev/null 2>&1 && wineserver -w &&
    test -f "$p/drive_c/windows/system32/gecko/plugin/npmshtml.dll" &&
    test -f "$p/drive_c/windows/syswow64/gecko/plugin/npmshtml.dll" &&
    test -d "$p/drive_c/windows/mono/mono-2.0"' \
    || fail "Gecko $gecko (x86 + x86_64) or Mono not installed into a fresh prefix"
pass
