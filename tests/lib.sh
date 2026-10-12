# shellcheck shell=bash
# Helpers shared by tests/cases/*.sh. Each case runs in its own bash process.
set -euo pipefail

IMAGE=${IMAGE:?IMAGE must be set (run cases through tests/run IMAGE)}
RUNTIME=${RUNTIME:-docker}
TEST_LABEL="desktop-test=$$"
TEST_NAME=$(basename "$0" .sh)
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Same restrictions as run-local and OpenShift restricted-v2.
HARDENED_BASE=(--user 123456:0 --read-only --cap-drop ALL --security-opt no-new-privileges
    --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --shm-size 1g)
HARDENED=("${HARDENED_BASE[@]}" --tmpfs /home/wineuser:mode=0770)

cleanup() {
    local ids
    ids=$("$RUNTIME" ps -aq --filter "label=$TEST_LABEL")
    [ -z "$ids" ] || "$RUNTIME" rm -f $ids >/dev/null
    ids=$("$RUNTIME" volume ls -q --filter "label=$TEST_LABEL")
    [ -z "$ids" ] || "$RUNTIME" volume rm -f $ids >/dev/null
}
trap cleanup EXIT

fail() { echo "FAIL [$TEST_NAME]: $*" >&2; exit 1; }
pass() { echo "PASS [$TEST_NAME]${1:+: $1}"; }

start_desktop() {
    local name="dt-$$-$1"
    shift
    "$RUNTIME" run -d --label "$TEST_LABEL" --name "$name" "${HARDENED[@]}" "$@" "$IMAGE" >/dev/null
    echo "$name"
}

run_cmd() { "$RUNTIME" run --rm --label "$TEST_LABEL" "${HARDENED[@]}" "$@"; }

# run_home VOLUME [run-args...] IMAGE CMD... : like run_cmd, with VOLUME as the home directory
run_home() {
    local vol=$1
    shift
    "$RUNTIME" run --rm --label "$TEST_LABEL" "${HARDENED_BASE[@]}" -v "$vol:/home/wineuser" "$@"
}

new_volume() {
    local vol="dt-$$-$1"
    "$RUNTIME" volume create --label "$TEST_LABEL" "$vol" >/dev/null
    echo "$vol"
}

exec_in() {
    local name=$1
    shift
    "$RUNTIME" exec "$name" "$@"
}

# logs_contain NAME PATTERN: capture first, never pipe into grep -q (SIGPIPE under pipefail)
logs_contain() { local out; out=$("$RUNTIME" logs "$1" 2>&1); grep -q -- "$2" <<<"$out"; }

poll() {
    local timeout=$1 what=$2
    shift 2
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || fail "timed out after ${timeout}s waiting for $what"
        sleep 1
    done
}

wait_healthy() {
    local name=$1 timeout=${2:-180}
    local deadline=$((SECONDS + timeout))
    until exec_in "$name" /usr/local/bin/desktop healthcheck >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            "$RUNTIME" logs "$name" >&2 || true
            fail "$name not healthy after ${timeout}s"
        fi
        sleep 1
    done
}

# fixture_image PREFIX_VERSION -> tag of a tiny derived image built FROM $IMAGE
fixture_image() {
    local tag="desktop-test-fixture:${1:-none}"
    "$RUNTIME" build -q -t "$tag" --build-arg "BASE_IMAGE=$IMAGE" --build-arg "PREFIX_VERSION=$1" \
        "$REPO_ROOT/tests/fixtures/derived" >/dev/null || fail "could not build fixture image $tag"
    echo "$tag"
}
