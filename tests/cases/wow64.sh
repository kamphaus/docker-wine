#!/usr/bin/env bash
# The image runs Wine in WoW64 mode: no 32-bit Linux packages, yet 32-bit Windows programs run.
source "$(dirname "$0")/../lib.sh"

out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c \
    'dpkg --print-foreign-architectures; dpkg-query -W -f "\${Package}:\${Architecture}\n" | grep -v ":amd64$\|:all$" || true') \
    || fail "could not list installed packages"
[ -z "$out" ] || fail "non-amd64 architectures or packages present: $out"

out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c 'command -v wine64 || true')
[ -z "$out" ] || fail "wine64 present ($out): not a WoW64 build"

# Runs as uid 123456 (run_cmd): 32-bit programs must work without libnss-wrapper:i386
out=$(run_cmd "$IMAGE" bash -c 'xvfb-run -a wine "C:\\windows\\syswow64\\cmd.exe" /c ver 2>/dev/null') \
    || fail "32-bit cmd.exe failed: $out"
grep -q "Microsoft Windows" <<<"$out" || fail "32-bit cmd.exe printed: $out"
pass
