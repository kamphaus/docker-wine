#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
run_cmd "$IMAGE" bash -c 'xvfb-run -a winetricks -q corefonts >/dev/null && test -f "$WINEPREFIX/drive_c/windows/Fonts/arial.ttf"' \
    || fail "winetricks -q corefonts failed"
pass
