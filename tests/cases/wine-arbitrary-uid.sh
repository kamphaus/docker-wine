#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
out=$(run_cmd "$IMAGE" bash -c 'xvfb-run -a wine cmd /c ver 2>/dev/null')
grep -q "Microsoft Windows" <<<"$out" || fail "wine cmd /c ver under uid 123456 printed: $out"
pass
