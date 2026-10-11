#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT

url='https://raw.githubusercontent.com/Winetricks/winetricks/{version}/src/winetricks'
good=431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
printf '# comment\r\n\r\nwinetricks b76e1ee79ac57d7aceb384f74518fc423265810c %s sha256:%s\r\n' "$url" "$good" > "$dir/good.lock"
printf 'winetricks b76e1ee79ac57d7aceb384f74518fc423265810c %s sha256:%s\n' "$url" "${good//4/5}" > "$dir/bad.lock"
printf 'winetricks 1 http://example.com/x sha256:%s\n' "$good" > "$dir/http.lock"
chmod -R a+rX "$dir"

run_cmd -v "$dir:/locks:ro" "$IMAGE" bash -c 'fetch-verified /locks/good.lock /tmp/out && test -s /tmp/out/winetricks' \
    || fail "valid CRLF lock file rejected"

out=$(run_cmd -v "$dir:/locks:ro" "$IMAGE" bash -c \
    'fetch-verified /locks/bad.lock /tmp/out 2>/tmp/err; rc=$?; cat /tmp/err; echo "rc=$rc files=[$(ls -A /tmp/out)]"')
grep -q "checksum mismatch for winetricks" <<<"$out" || fail "unexpected output: $out"
grep -q 'rc=1 files=\[\]' <<<"$out" || fail "mismatch accepted or file left behind: $out"

out=$(run_cmd -v "$dir:/locks:ro" "$IMAGE" fetch-verified /locks/http.lock /tmp/out 2>&1) && fail "http URL accepted"
grep -q "only https:// URLs are allowed" <<<"$out" || fail "unexpected output: $out"
pass
