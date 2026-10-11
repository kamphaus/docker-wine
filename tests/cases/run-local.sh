#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
name="dt-$$-runlocal"
vol="dt-$$-runlocal-home"
port=$((20000 + $$ % 20000))
trap '"$RUNTIME" rm -f "$name" >/dev/null 2>&1; "$RUNTIME" volume rm -f "$vol" >/dev/null 2>&1; cleanup' EXIT

"$REPO_ROOT/run-local" "$IMAGE" --name "$name" --home-volume "$vol" --port "$port" --ephemeral >/dev/null \
    || fail "run-local failed"
[ "$("$RUNTIME" port "$name" 3389/tcp)" = "127.0.0.1:$port" ] || fail "published on: $("$RUNTIME" port "$name" 3389/tcp)"
[ "$("$RUNTIME" inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "$name")" = "1001:0 true [ALL]" ] \
    || fail "not hardened: $("$RUNTIME" inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "$name")"
env_out=$("$RUNTIME" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name")
grep -qx PREFIX_MODE=ephemeral <<<"$env_out" || fail "--ephemeral not applied"
wait_healthy "$name" 180

out=$("$REPO_ROOT/run-local" does-not-exist.invalid/image:never 2>&1) && fail "accepted a missing image"
grep -q "not found locally" <<<"$out" || fail "unexpected output: $out"

out=$("$REPO_ROOT/run-local" "$IMAGE" --port 99999 2>&1) && fail "accepted port 99999"
grep -q "invalid port" <<<"$out" || fail "unexpected output: $out"
pass
