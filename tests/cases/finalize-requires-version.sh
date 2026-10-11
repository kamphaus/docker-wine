#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
log=$(mktemp)
trap 'cleanup; rm -f "$log"' EXIT
if "$RUNTIME" build --progress=plain --build-arg "BASE_IMAGE=$IMAGE" --build-arg PREFIX_VERSION= \
    "$REPO_ROOT/tests/fixtures/derived" >"$log" 2>&1; then
    fail "finalize succeeded without PREFIX_VERSION"
fi
grep -q "PREFIX_VERSION must be set" "$log" || fail "unclear finalize error: $(tail -n5 "$log")"

if "$RUNTIME" build --progress=plain --build-arg "BASE_IMAGE=$IMAGE" --build-arg PREFIX_VERSION=my/app \
    "$REPO_ROOT/tests/fixtures/derived" >"$log" 2>&1; then
    fail "finalize accepted PREFIX_VERSION=my/app"
fi
grep -q "PREFIX_VERSION 'my/app' is invalid" "$log" || fail "unclear finalize error: $(tail -n5 "$log")"
pass
