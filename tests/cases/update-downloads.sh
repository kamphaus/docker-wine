#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT
mkdir -p "$dir/scripts"
cp "$REPO_ROOT/scripts/update-downloads" "$dir/scripts/"
cat > "$dir/test.lock" <<'EOT'
# keep this comment
winetricks b76e1ee79ac57d7aceb384f74518fc423265810c https://raw.githubusercontent.com/Winetricks/winetricks/{version}/src/winetricks sha256:pending
EOT
"$dir/scripts/update-downloads" "$dir/test.lock" >/dev/null
grep -qx '# keep this comment' "$dir/test.lock" || fail "comment lost"
grep -q 'sha256:431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b$' "$dir/test.lock" \
    || fail "checksum not updated: $(cat "$dir/test.lock")"
grep -q '/{version}/src/winetricks' "$dir/test.lock" || fail "URL template was expanded in the lock file"
# --- §6.3: only changed versions are rehashed; unchanged entries are verified ---
good=431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
bad=0000000000000000000000000000000000000000000000000000000000000000
url='https://raw.githubusercontent.com/Winetricks/winetricks/{version}/src/winetricks'
v=b76e1ee79ac57d7aceb384f74518fc423265810c
entry() { printf 'winetricks %s %s sha256:%s\n' "$1" "$url" "$2"; }

# no base ref: a wrong, non-pending hash must FAIL and must not be rewritten
entry $v $bad > "$dir/wrong.lock"
if "$dir/scripts/update-downloads" "$dir/wrong.lock" >/dev/null 2>&1; then fail "wrong hash accepted without base"; fi
[ "$(cat "$dir/wrong.lock")" = "$(entry $v $bad)" ] || fail "wrong hash was rewritten"

# pending is recomputed even without a base ref
entry $v pending > "$dir/pending.lock"
"$dir/scripts/update-downloads" "$dir/pending.lock" >/dev/null
[ "$(cat "$dir/pending.lock")" = "$(entry $v $good)" ] || fail "pending not recomputed"

# with a base ref
git -C "$dir" init -q
git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$dir/x"; entry $v $bad > "$dir/x/a.lock"
git -C "$dir" add x/a.lock
git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m base
# unchanged version + wrong hash: FAIL, not rewritten
if BASE_REF=HEAD "$dir/scripts/update-downloads" "$dir/x/a.lock" >/dev/null 2>&1; then fail "unchanged version with wrong hash accepted"; fi
[ "$(cat "$dir/x/a.lock")" = "$(entry $v $bad)" ] || fail "unchanged entry was rewritten"
# --base flag behaves like BASE_REF
if "$dir/scripts/update-downloads" --base HEAD "$dir/x/a.lock" >/dev/null 2>&1; then fail "--base: wrong hash accepted"; fi
# changed version (stale hash kept by Renovate): rewritten
printf 'winetricks 20260125 https://raw.githubusercontent.com/Winetricks/winetricks/b76e1ee79ac57d7aceb384f74518fc423265810c/src/winetricks sha256:%s\n' $bad > "$dir/x/a.lock"
BASE_REF=HEAD "$dir/scripts/update-downloads" "$dir/x/a.lock" >/dev/null
grep -q "sha256:$good\$" "$dir/x/a.lock" || fail "changed version not rehashed: $(cat "$dir/x/a.lock")"
# entry new relative to base: rehashed
printf 'other %s %s sha256:%s\n' $v "$url" $bad >> "$dir/x/a.lock"
BASE_REF=HEAD "$dir/scripts/update-downloads" "$dir/x/a.lock" >/dev/null
[ "$(grep -c "sha256:$good\$" "$dir/x/a.lock")" = 2 ] || fail "new entry not rehashed"
pass
