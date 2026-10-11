#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
name=$(start_desktop smoke)
wait_healthy "$name" 180
logs_contain "$name" "using Wine prefix /home/wineuser/.wine (PREFIX_MODE=seed)" \
    || fail "hook did not report the prefix"
pass
