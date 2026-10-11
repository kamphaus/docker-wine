#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT
mkdir -p "$dir/scripts"
cp "$REPO_ROOT/scripts/update-downloads" "$dir/scripts/"
cat > "$dir/test.lock" <<'EOT'
# keep this comment
winetricks b76e1ee79ac57d7aceb384f74518fc423265810c https://raw.githubusercontent.com/Winetricks/winetricks/{version}/src/winetricks sha256:0000000000000000000000000000000000000000000000000000000000000000
EOT
"$dir/scripts/update-downloads" "$dir/test.lock" >/dev/null
grep -qx '# keep this comment' "$dir/test.lock" || fail "comment lost"
grep -q 'sha256:431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b$' "$dir/test.lock" \
    || fail "checksum not updated: $(cat "$dir/test.lock")"
grep -q '/{version}/src/winetricks' "$dir/test.lock" || fail "URL template was expanded in the lock file"
pass
