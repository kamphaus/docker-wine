# Plan 1: Rootless docker-remote-desktop base image

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `kamphaus/docker-remote-desktop` into a rootless, pinned, OpenShift-compatible XFCE + xrdp image with audio and clipboard, published to `ghcr.io/kamphaus/docker-remote-desktop`.

**Architecture:** A bash supervisor (`/usr/local/bin/desktop`, run under `tini`) runs as whatever UID the container gets. It maps that UID to the user `wineuser` with nss_wrapper, generates a TLS key, and starts Xorg+xorgxrdp, xrdp-chansrv, PulseAudio (with the xrdp sink and source modules) and XFCE. It then starts xrdp configured to connect directly to that display, so sesman, PAM and root are never needed. Every build input is pinned (base image digest, Ubuntu snapshot, git tag plus commit). CI builds the image once, tests it, scans it, and then pushes, attests and signs that same image.

**Tech Stack:** Ubuntu 24.04, xrdp 0.9.24, xorgxrdp 0.9.19, pulseaudio-module-xrdp v0.8, nss_wrapper, tini, bash, Docker/buildx, GitHub Actions, Renovate (Mend-hosted app), Trivy, cosign.

**Spec:** `docker-wine` repo, `docs/superpowers/specs/2026-10-11-rootless-openshift-design.md`, on branch `design/rootless-openshift`. Read Section 0 (Revisions) first.

## Global Constraints

- Repository: `/mnt/c/Users/cfree/Code/docker-wine-rdp/docker-remote-desktop`, branch `feat/rootless-desktop`, created from `master`.
- Every commit message ends with the trailer `Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not add a `Co-Authored-By` trailer.
- Pushing branches, opening PRs and changing GitHub settings are outward-facing. Confirm with the user before each one.
- The repo is on a Windows filesystem. All scripts must keep LF line endings, which `.gitattributes` in Task 2 enforces. `chmod +x` cannot be relied on, so the Dockerfile sets modes explicitly.
- Base image: `ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55`.
- Initial Ubuntu snapshot: `20261001T000000Z`.
- pulseaudio-module-xrdp: tag `v0.8`, commit `f36911ee49a85dce19ecc3d53b0edaee624c9faa`.
- Image user: `USER 1001`, primary group 0, username `wineuser`, `HOME=/home/wineuser`.
- Writable paths: `/home/wineuser`, `/run/desktop`, `/tmp`. `/run/xrdp` is a symlink to `/run/desktop/xrdp`.
- Display `:10`. Sockets: `/run/xrdp/sockdir/xrdp_display_10` and `/run/xrdp/sockdir/xrdp_chansrv_socket_10`. Audio socket when a client is connected: `/run/xrdp/sockdir/xrdp_chansrv_audio_out_socket_10`.
- `RDP_LISTEN_ADDRESS` defaults to `127.0.0.1`. It must be an IPv4 address. The port is always 3389.
- Entrypoint: `["/usr/bin/tini", "--", "/usr/local/bin/desktop"]`. `desktop healthcheck` is reserved for the probe; any other arguments select command mode.
- Removed from the image: Firefox, the Mozilla PPA, `git`, `vim`, `software-properties-common`, `sudo`, `xfce4-goodies`, and every screen locker.
- Pinned GitHub Actions:

  | Action | Version | Commit |
  |---|---|---|
  | `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
  | `docker/setup-buildx-action` | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
  | `docker/build-push-action` | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
  | `docker/login-action` | v4.6.0 | `dbcb813823bdd20940b903addbd779551569679f` |
  | `actions/upload-artifact` | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
  | `actions/download-artifact` | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
  | `actions/attest-build-provenance` | v4.2.2 | `4d101475d8b20a2381f78447822ac1eab6504dd8` |
  | `actions/attest-sbom` | v4.1.0 | `c604332985a26aa8cf1bdc465b92731239ec6b9e` |
  | `sigstore/cosign-installer` | v4.1.2 | `6f9f17788090df1f26f669e9d70d6ae9567deba6` |

- Trivy image: `aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa`.
- Test convention: test cases are standalone bash scripts in `tests/cases/*.sh`. They are run by `tests/run IMAGE [CASE...]` and source `tests/lib.sh`. All containers are hardened: `--user 123456:0 --read-only --cap-drop ALL --security-opt no-new-privileges` plus tmpfs mounts.
- **Read-only root contingency:** if Task 1 records "read-only root: unsupported", remove `--read-only` from `HARDENED` in `tests/lib.sh` (Task 2) and from every place that copies it.

## Review Focus

These are the inputs and failure modes most likely to hurt a user that the spec's own tests don't cover. Each has a test in the task listed.

1. **Container restart without tmpfs** (`docker restart`, or the image run without `--read-only`): stale `/tmp/.X10-lock`, X sockets and xrdp PID files would block Xorg or xrdp. Expected: the desktop becomes healthy again. *Task 4, `lifecycle.sh`.*
2. **Screen locker on a password-less desktop:** a locker would lock the user out permanently. Expected: no locker binaries in the image. *Task 3, `image-hardening.sh`.*
3. **Only one of `tls.crt`/`tls.key` mounted:** xrdp would fail with an obscure error. Expected: a clear error and a non-zero exit. *Task 4, `tls.sh`.*
4. **Reconnecting after a disconnect:** expected to resume the same session (the same Xorg process), not start a new one. *Task 5, `rdp-e2e.sh`.*
5. **CRLF line endings** from the Windows checkout breaking `#!/usr/bin/env bash` scripts. Expected: no CR bytes in the scripts installed in the image. *Task 3, `image-hardening.sh`.*

---

### Task 1: M0 verification spike (throwaway, decision gate)

**Files:**
- Create (scratch only, never committed): `$SCRATCH/m0/Dockerfile`, `$SCRATCH/m0/spike.sh`, `$SCRATCH/m0/client.Dockerfile`, where `SCRATCH=/tmp/m0-spike`
- Modify: `docker-wine` repo, `docs/superpowers/specs/2026-10-11-rootless-openshift-design.md`, adding a §3.4 "M0 results" subsection

**Interfaces:**
- Consumes: nothing.
- Produces: recorded answers to spec §3.4 items 1–3, plus whether `autorun` with `username=na` skips the login screen and whether FreeRDP's `/sound:sys:fake` opens the audio channel. Tasks 4 and 5 rely on all of these.

- [ ] **Step 1: Write the spike image**

```bash
mkdir -p /tmp/m0-spike && cd /tmp/m0-spike
cat > Dockerfile <<'EOF'
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xrdp xorgxrdp dbus-x11 xfce4 xfce4-terminal pulseaudio pulseaudio-utils libnss-wrapper openssl \
 && rm -rf /var/lib/apt/lists/*
RUN rm -rf /run/xrdp && ln -s /run/desktop/xrdp /run/xrdp \
 && useradd -u 1001 -g 0 -d /home/wineuser -M -s /bin/bash wineuser \
 && mkdir -p /home/wineuser /run/desktop && chgrp -R 0 /home/wineuser /run/desktop && chmod -R g=u /home/wineuser /run/desktop \
 && printf '[Chansrv]\nEnableFuseMount=false\n[ChansrvLogging]\nLogLevel=INFO\nEnableSyslog=false\n' > /etc/xrdp/sesman.ini
USER 1001
EOF
cat > spike.sh <<'EOF'
#!/usr/bin/env bash
set -x
R=/run/desktop; mkdir -p $R/log $R/xrdp/sockdir $R/xdg $R/tls; chmod 700 $R/xdg
export XDG_RUNTIME_DIR=$R/xdg HOME=/home/wineuser
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj /CN=spike -keyout $R/tls/tls.key -out $R/tls/tls.crt 2>/dev/null
XRDP_SOCKET_PATH=/run/xrdp/sockdir /usr/lib/xorg/Xorg :10 -config xrdp/xorg.conf -noreset -nolisten tcp -logfile $R/log/Xorg.log &
for i in $(seq 100); do [ -S /run/xrdp/sockdir/xrdp_display_10 ] && break; sleep 0.2; done
export DISPLAY=:10
CHANSRV_LOG_PATH=$R/log /usr/sbin/xrdp-chansrv &
dbus-launch --exit-with-session startxfce4 &
cat > $R/xrdp.ini <<INI
[Globals]
ini_version=1
fork=true
port=tcp://127.0.0.1:3389
security_layer=tls
certificate=$R/tls/tls.crt
key_file=$R/tls/tls.key
ssl_protocols=TLSv1.2, TLSv1.3
autorun=Desktop
allow_channels=true
max_bpp=32
[Logging]
LogFile=$R/log/xrdp.log
LogLevel=INFO
EnableConsole=true
EnableSyslog=false
[Channels]
rdpdr=false
rdpsnd=true
drdynvc=true
cliprdr=true
[Desktop]
name=Desktop
lib=libxup.so
username=na
password=na
ip=127.0.0.1
port=/run/xrdp/sockdir/xrdp_display_10
chansrvport=DISPLAY(10)
code=20
INI
exec /usr/sbin/xrdp --nodaemon --config $R/xrdp.ini
EOF
cat > client.Dockerfile <<'EOF'
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends freerdp2-x11 xvfb xauth \
 && rm -rf /var/lib/apt/lists/*
EOF
docker build -q -t m0-spike . && docker build -q -t m0-client -f client.Dockerfile .
```

Expected: both builds print an image ID.

- [ ] **Step 2: Start the spike rootless and read-only**

```bash
docker run -d --name m0 --user 123456:0 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --tmpfs /home/wineuser:mode=0770 --shm-size 1g \
  -v /tmp/m0-spike/spike.sh:/spike.sh:ro m0-spike bash /spike.sh
sleep 15; docker logs m0 2>&1 | tail -20
docker exec m0 ls -la /run/xrdp/ /run/xrdp/sockdir/
```

Expected: `xrdp_display_10` and `xrdp_chansrv_socket_10` exist, `/run/xrdp/xrdp.pid` exists, and xrdp is still running.

- [ ] **Step 3: Connect a client and check checks 1, 2, autorun and fake sound**

```bash
docker run -d --name m0c --network container:m0 m0-client \
  xvfb-run -a xfreerdp /v:127.0.0.1:3389 /cert:ignore /sec:tls /u:wineuser /p:unused /sound:sys:fake +clipboard
sleep 15
docker exec m0 grep -c 'connected to X11rdp_pid' /run/desktop/log/xrdp.log
docker exec m0 ls /run/xrdp/sockdir/
docker exec m0 grep -i -E 'error|fail' /run/desktop/log/xrdp.log /run/desktop/log/xrdp-chansrv.10.log
docker exec m0 awk '$4=="0A"{print $2}' /proc/net/tcp
```

Expected:
- A count of `1`.
- `xrdp_chansrv_audio_out_socket_10` is listed.
- No permission errors.
- Exactly one listener, `0100007F:0D3D`.

This confirms check 1 (direct connect plus chansrv), check 2 (paths), that autorun needs no login, and that fake sound opens the audio channel.

- [ ] **Step 4: Check 3, keymap under a read-only root**

```bash
docker exec m0 grep -i -E 'xkb|keymap|xkm' /run/desktop/log/Xorg.log
```

Expected: no `Failed to compile keymap` or `Couldn't open compiled keymap` lines. Xorg falls back to writing compiled keymaps under `/tmp`.

- [ ] **Step 5: Record results and clean up**

```bash
docker rm -f m0c m0
```

In the spec, append this under §3.4, with the actual observations filled in from Steps 2–4:

```markdown
#### M0 results (YYYY-MM-DD)

- Direct connect + `chansrvport` on xrdp 0.9.24-4: **works / fails**. Evidence: …
- Runtime paths under `/run/desktop` via the `/run/xrdp` symlink: **works / fails**. Evidence: …
- Read-only root (xkb): **supported / unsupported**. Evidence: …
- `autorun=Desktop` with `username=na`: login screen **skipped / shown**.
- FreeRDP `/sound:sys:fake` opens the audio channel: **yes / no**.
- Decision: **packaged xrdp 0.9.24** / **source-built xrdp 0.10.x (stop and re-plan)**.
```

- [ ] **Step 6: Decision gate**

- If any of direct connect, runtime paths, autorun or fake sound **fails**: stop. Report to the user. The source-build fallback needs a new plan.
- If read-only root is unsupported: continue, applying the read-only root contingency from Global Constraints. Add `RUN install -d -g 0 -m 0775 /var/lib/xkb` to the final stage in Task 4.
- Commit the spec change in the `docker-wine` repo:

```bash
cd /mnt/c/Users/cfree/Code/docker-wine-rdp/docker-wine
git add docs/superpowers/specs/2026-10-11-rootless-openshift-design.md
git commit -m "docs(spec): record M0 verification results" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Repo cleanup, pinned apt foundation and test harness

**Files:**
- Create: `.gitattributes`, `build/apt-snapshot`, `tests/run`, `tests/lib.sh`, `tests/cases/apt-snapshot.sh`
- Modify: `Dockerfile` (full rewrite, skeleton)
- Delete: `deploy`, `.github/workflows/build.yml`, `.github/workflows/test.yml`

**Interfaces:**
- Produces:
  - `build/apt-snapshot SNAPSHOT_ID`: rejects IDs that don't match `^[0-9]{8}T[0-9]{6}Z$`, bootstraps `ca-certificates`, and writes `Snapshot:` into `ubuntu.sources`.
  - `tests/lib.sh` functions: `fail MSG`, `pass [MSG]`, `start_desktop SUFFIX [run-args...]` (prints the container name), `run_cmd [run-args...] IMAGE CMD...`, `exec_in NAME CMD...`, `poll SECONDS WHAT CMD...`, `wait_healthy NAME [SECONDS]`, `wait_exit NAME SECONDS` (prints the exit code), `listening_on NAME HEXADDR:HEXPORT`, `build_rdp_client` (prints the image tag).
  - Variables: `IMAGE`, `RUNTIME`, `TEST_LABEL`, `HARDENED`, `REPO_ROOT`.

- [ ] **Step 1: Create the branch and line-ending rules**

```bash
cd /mnt/c/Users/cfree/Code/docker-wine-rdp/docker-remote-desktop
git switch -c feat/rootless-desktop
cat > .gitattributes <<'EOF'
* text=auto eol=lf
*.png binary
EOF
git rm -q deploy .github/workflows/build.yml .github/workflows/test.yml
```

- [ ] **Step 2: Write the test harness**

`tests/run`:

```bash
#!/usr/bin/env bash
# Run the image test suite: tests/run IMAGE [tests/cases/NAME.sh ...]
set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: tests/run IMAGE [tests/cases/NAME.sh ...]" >&2
    exit 2
fi
export IMAGE=$1
shift
cd "$(dirname "$0")/.."

cases=("$@")
[ ${#cases[@]} -gt 0 ] || cases=(tests/cases/*.sh)

failed=()
for c in "${cases[@]}"; do
    echo "=== ${c}"
    bash "$c" || failed+=("$c")
done

if [ ${#failed[@]} -gt 0 ]; then
    printf 'FAILED: %s\n' "${failed[@]}" >&2
    exit 1
fi
echo "all ${#cases[@]} test cases passed"
```

`tests/lib.sh`:

```bash
# shellcheck shell=bash
# Helpers shared by tests/cases/*.sh. Each case runs in its own bash process.
set -euo pipefail

IMAGE=${IMAGE:?IMAGE must be set (run cases through tests/run IMAGE)}
RUNTIME=${RUNTIME:-docker}
TEST_LABEL="desktop-test=$$"
TEST_NAME=$(basename "$0" .sh)
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Same restrictions as run-local and OpenShift restricted-v2.
HARDENED=(--user 123456:0 --read-only --cap-drop ALL --security-opt no-new-privileges
    --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --tmpfs /home/wineuser:mode=0770
    --shm-size 1g)

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

exec_in() {
    local name=$1
    shift
    "$RUNTIME" exec "$name" "$@"
}

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
    local name=$1 timeout=${2:-90}
    local deadline=$((SECONDS + timeout))
    until exec_in "$name" /usr/local/bin/desktop healthcheck >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            "$RUNTIME" logs "$name" >&2 || true
            fail "$name not healthy after ${timeout}s"
        fi
        sleep 1
    done
}

wait_exit() {
    local name=$1 timeout=$2
    timeout "$timeout" "$RUNTIME" wait "$name" || fail "$name still running after ${timeout}s"
}

# listening_on NAME 0100007F:0D3D -> true if a TCP socket is in LISTEN state on that address
listening_on() {
    exec_in "$1" awk -v want="$2" '$4 == "0A" && toupper($2) == want {found = 1} END {exit !found}' /proc/net/tcp
}

build_rdp_client() {
    "$RUNTIME" build -q -t desktop-test-rdp-client -f "$REPO_ROOT/tests/rdp-client/Dockerfile" "$REPO_ROOT" >/dev/null
    echo desktop-test-rdp-client
}
```

- [ ] **Step 3: Write the failing test**

`tests/cases/apt-snapshot.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

out=$("$RUNTIME" run --rm --entrypoint grep "$IMAGE" -c '^Snapshot: [0-9]\{8\}T[0-9]\{6\}Z$' /etc/apt/sources.list.d/ubuntu.sources) \
    || fail "no Snapshot: lines in ubuntu.sources"
[ "$out" -ge 2 ] || fail "expected a Snapshot: line per stanza, found $out"

if out=$("$RUNTIME" run --rm --user 0 --entrypoint /usr/local/sbin/apt-snapshot "$IMAGE" 2026-10-01 2>&1); then
    fail "apt-snapshot accepted an invalid id"
fi
grep -q "invalid snapshot id" <<<"$out" || fail "unexpected output: $out"
pass
```

- [ ] **Step 4: Run it to verify it fails**

```bash
docker build -t desktop:dev . ; tests/run desktop:dev tests/cases/apt-snapshot.sh
```

Expected: FAIL. Either the build fails (the old Dockerfile still clones without pinning), or the case fails with `no Snapshot: lines in ubuntu.sources`.

- [ ] **Step 5: Implement `build/apt-snapshot` and the Dockerfile skeleton**

`build/apt-snapshot`:

```bash
#!/usr/bin/env bash
# Pin every Ubuntu apt source of this image to a snapshot.ubuntu.com timestamp.
# Usage: apt-snapshot YYYYMMDDTHHMMSSZ
set -euo pipefail

snapshot=${1:-}
if ! [[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "apt-snapshot: invalid snapshot id '$snapshot' (expected YYYYMMDDTHHMMSSZ)" >&2
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# snapshot.ubuntu.com is HTTPS-only and the base image has no CA bundle: bootstrap it first.
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null

sed -i -e '/^Snapshot:/d' -e "/^Components:/a Snapshot: ${snapshot}" /etc/apt/sources.list.d/ubuntu.sources
apt-get update -qq
apt-get install -y -qq --no-install-recommends --allow-downgrades ca-certificates >/dev/null
rm -rf /var/lib/apt/lists/*
```

`Dockerfile` (a skeleton; Task 3 extends it):

```dockerfile
# syntax=docker/dockerfile:1

# Ubuntu archive snapshot for every apt operation; bumped weekly by .github/workflows/snapshot-bump.yml
ARG UBUNTU_SNAPSHOT=20261001T000000Z

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS base
ARG UBUNTU_SNAPSHOT
COPY --chmod=0755 build/apt-snapshot /usr/local/sbin/apt-snapshot
RUN apt-snapshot "${UBUNTU_SNAPSHOT}"

FROM base
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
docker build -t desktop:dev . && tests/run desktop:dev tests/cases/apt-snapshot.sh
```

Expected: `PASS [apt-snapshot]`.

- [ ] **Step 7: Commit**

```bash
git add -A .gitattributes build/apt-snapshot Dockerfile tests
git commit -m "build: pin apt to Ubuntu snapshots and add test harness" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Rootless identity, command mode and init hooks

**Files:**
- Create: `rootfs/usr/local/bin/desktop`, `rootfs/usr/local/lib/desktop/common.sh`, `rootfs/etc/desktop/init.d/.keep`, and test cases `tests/cases/command-mode.sh`, `tests/cases/init-hooks.sh`, `tests/cases/unwritable-runtime.sh`, `tests/cases/image-hardening.sh`
- Modify: `Dockerfile`, `entrypoint.sh` (deleted)

**Interfaces:**
- Consumes: Task 2's `base` stage and `tests/lib.sh`.
- Produces, used by Task 4 and by Plan 2's init hooks:
  - `common.sh` functions: `log MSG...`, `die MSG...`, `is_true VALUE`, `require_writable DIR...`, `setup_runtime_dirs`, `setup_identity`, `run_init_hooks`.
  - Variables: `DESKTOP_RUNTIME_DIR` (`/run/desktop`), `DESKTOP_USER` (`wineuser`), exported `XDG_RUNTIME_DIR=/run/desktop/xdg`.
  - Hook contract: every `/etc/desktop/init.d/*.sh` is *sourced* in lexical order, in both desktop and command mode. A hook may call `log` and `die` and may `export` variables. A non-zero final status aborts startup with `init hook <path> failed`.

- [ ] **Step 1: Write the failing tests**

`tests/cases/command-mode.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

out=$(run_cmd "$IMAGE" id -un) || fail "id -un failed under an arbitrary uid"
[ "$out" = wineuser ] || fail "arbitrary uid maps to '$out', expected wineuser"

out=$(run_cmd "$IMAGE" bash -c 'echo "$HOME"')
[ "$out" = /home/wineuser ] || fail "HOME is '$out'"

out=$("$RUNTIME" run --rm --label "$TEST_LABEL" "$IMAGE" id -un)
[ "$out" = wineuser ] || fail "default uid 1001 maps to '$out'"
pass
```

`tests/cases/init-hooks.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT
mkdir "$dir/ok" "$dir/bad"
printf 'export HOOK_MARKER=from-hook\n' > "$dir/ok/10-marker.sh"
printf 'log "about to fail"\nfalse\n' > "$dir/bad/20-fail.sh"
chmod -R a+rX "$dir"

out=$(run_cmd -v "$dir/ok:/etc/desktop/init.d:ro" "$IMAGE" printenv HOOK_MARKER) || fail "hook run failed"
[ "$out" = from-hook ] || fail "exported variable not visible: '$out'"

if out=$(run_cmd -v "$dir/bad:/etc/desktop/init.d:ro" "$IMAGE" true 2>&1); then
    fail "failing hook did not abort startup"
fi
grep -q "init hook /etc/desktop/init.d/20-fail.sh failed" <<<"$out" || fail "unexpected output: $out"
pass
```

`tests/cases/unwritable-runtime.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

if out=$("$RUNTIME" run --rm --label "$TEST_LABEL" --user 123456:0 --read-only "$IMAGE" true 2>&1); then
    fail "started although /run/desktop is read-only"
fi
grep -q "/run/desktop is not writable" <<<"$out" || fail "unexpected output: $out"
pass
```

`tests/cases/image-hardening.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

out=$("$RUNTIME" run --rm --user 0 --entrypoint find "$IMAGE" / -xdev -perm /6000 -type f)
[ -z "$out" ] || fail "setuid/setgid files present: $out"

out=$("$RUNTIME" run --rm --user 0 --entrypoint bash "$IMAGE" -c \
    'ls /etc/xrdp/cert.pem /etc/xrdp/key.pem /etc/xrdp/rsakeys.ini /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem 2>/dev/null; true')
[ -z "$out" ] || fail "key material baked into image: $out"

out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c \
    'for b in xfce4-screensaver light-locker xscreensaver gnome-screensaver sudo firefox git vim; do command -v "$b"; done; true')
[ -z "$out" ] || fail "forbidden binaries present: $out"

out=$("$RUNTIME" run --rm --entrypoint bash "$IMAGE" -c \
    "grep -l \$'\\r' /usr/local/bin/desktop /usr/local/lib/desktop/*.sh /usr/local/sbin/apt-snapshot; true")
[ -z "$out" ] || fail "CRLF line endings in: $out"
pass
```

- [ ] **Step 2: Run them to verify they fail**

```bash
docker build -t desktop:dev . && tests/run desktop:dev tests/cases/command-mode.sh tests/cases/init-hooks.sh tests/cases/unwritable-runtime.sh tests/cases/image-hardening.sh
```

Expected: FAIL. There is no `wineuser` and no `desktop` entrypoint yet.

- [ ] **Step 3: Implement `common.sh`**

`rootfs/usr/local/lib/desktop/common.sh`:

```bash
# shellcheck shell=bash
# Shared helpers for /usr/local/bin/desktop and the init hooks in /etc/desktop/init.d.

DESKTOP_RUNTIME_DIR=${DESKTOP_RUNTIME_DIR:-/run/desktop}
DESKTOP_USER=wineuser

log() { printf '%s desktop: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

require_writable() {
    local dir
    for dir in "$@"; do
        if ! [ -d "$dir" ] || ! [ -w "$dir" ]; then
            die "$dir is not writable by uid $(id -u) gid $(id -g); mount a writable volume or tmpfs there"
        fi
    done
}

setup_runtime_dirs() {
    require_writable "$DESKTOP_RUNTIME_DIR" "$HOME" /tmp
    mkdir -p "$DESKTOP_RUNTIME_DIR"/{log,tls,nss,xrdp/sockdir,xdg}
    chmod 0700 "$DESKTOP_RUNTIME_DIR/xdg"
    export XDG_RUNTIME_DIR="$DESKTOP_RUNTIME_DIR/xdg"
}

# Give arbitrary UIDs (OpenShift restricted-v2) the stable name $DESKTOP_USER via nss_wrapper.
setup_identity() {
    local uid gid nss="$DESKTOP_RUNTIME_DIR/nss"
    uid=$(id -u)
    gid=$(id -g)
    export USER="$DESKTOP_USER" LOGNAME="$DESKTOP_USER"
    if [ "$(getent passwd "$uid" | cut -d: -f1)" = "$DESKTOP_USER" ]; then
        return 0
    fi
    grep -v "^${DESKTOP_USER}:" /etc/passwd > "$nss/passwd"
    printf '%s:x:%s:%s::%s:/bin/bash\n' "$DESKTOP_USER" "$uid" "$gid" "$HOME" >> "$nss/passwd"
    cp /etc/group "$nss/group"
    getent group "$gid" >/dev/null || printf '%s:x:%s:\n' "$DESKTOP_USER" "$gid" >> "$nss/group"
    export NSS_WRAPPER_PASSWD="$nss/passwd" NSS_WRAPPER_GROUP="$nss/group"
    export LD_PRELOAD="libnss_wrapper.so${LD_PRELOAD:+:$LD_PRELOAD}"
}

run_init_hooks() {
    local hook
    for hook in /etc/desktop/init.d/*.sh; do
        [ -e "$hook" ] || continue
        log "running init hook $hook"
        # shellcheck source=/dev/null
        source "$hook" || die "init hook $hook failed"
    done
}
```

- [ ] **Step 4: Implement the `desktop` entrypoint (command mode only for now)**

`rootfs/usr/local/bin/desktop`:

```bash
#!/usr/bin/env bash
# Container entrypoint: `desktop` starts the RDP desktop, `desktop CMD...` runs CMD as the
# desktop user, `desktop healthcheck` is the liveness/startup probe.
set -Eeuo pipefail
source /usr/local/lib/desktop/common.sh
trap 'die "command failed (${BASH_SOURCE[0]}:${LINENO}): ${BASH_COMMAND}"' ERR

main() {
    setup_runtime_dirs
    setup_identity
    if [ $# -gt 0 ]; then
        run_init_hooks
        exec "$@"
    fi
    die "desktop mode is not implemented yet"
}

main "$@"
```

- [ ] **Step 5: Extend the Dockerfile**

Replace the final `FROM base` line of `Dockerfile` with:

```dockerfile
FROM base
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libnss-wrapper locales tini \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/desktop \
 && chmod 0644 /usr/local/lib/desktop/*.sh \
 && deluser --remove-home ubuntu \
 && useradd --uid 1001 --gid 0 --home-dir /home/wineuser --no-create-home --shell /bin/bash wineuser \
 && mkdir -p /home/wineuser /run/desktop /etc/desktop/init.d \
 && chgrp -R 0 /home/wineuser /run/desktop \
 && chmod -R g=u /home/wineuser /run/desktop \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
ENV LANG=en_US.UTF-8 HOME=/home/wineuser
USER 1001
WORKDIR /home/wineuser
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/desktop"]
```

Then delete the old entrypoint and create the hook directory placeholder:

```bash
git rm -q entrypoint.sh
mkdir -p rootfs/etc/desktop/init.d && touch rootfs/etc/desktop/init.d/.keep
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
docker build -t desktop:dev . && tests/run desktop:dev tests/cases/command-mode.sh tests/cases/init-hooks.sh tests/cases/unwritable-runtime.sh tests/cases/image-hardening.sh tests/cases/apt-snapshot.sh
```

Expected: all five PASS.

- [ ] **Step 7: Commit**

```bash
git add -A Dockerfile rootfs tests entrypoint.sh
git commit -m "feat: rootless identity via nss_wrapper, command mode and init hooks" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Desktop session supervisor, TLS and xrdp configuration

**Files:**
- Create: `rootfs/usr/local/lib/desktop/tls.sh`, `rootfs/usr/local/lib/desktop/session.sh`, `rootfs/etc/desktop/xrdp.ini.tmpl`, `rootfs/etc/desktop/pulse/default.pa`, `rootfs/etc/xrdp/sesman.ini`, and test cases `tests/cases/arbitrary-uid.sh`, `tests/cases/no-root-processes.sh`, `tests/cases/tls.sh`, `tests/cases/listen-address.sh`, `tests/cases/lifecycle.sh`
- Modify: `Dockerfile`, `rootfs/usr/local/bin/desktop`

**Interfaces:**
- Consumes: Task 3's `common.sh` and the `desktop` entrypoint.
- Produces:
  - `desktop healthcheck`: exit 0 when healthy.
  - `session.sh` functions: `clean_stale_state`, `start_xorg`, `start_chansrv`, `start_pulseaudio`, `start_xfce`, `start_xrdp`, `supervise`.
  - `tls.sh` function `setup_tls`, which exports `TLS_CERT` and `TLS_KEY`.
  - `validate_config`.
  - Log lines Task 5 and Plan 2 rely on: `using mounted TLS certificate /etc/desktop/tls/tls.crt`, `desktop ready`, and xrdp's own `connected to X11rdp_pid` in `/run/desktop/log/xrdp.log`.

- [ ] **Step 1: Write the failing tests**

`tests/cases/arbitrary-uid.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
name=$(start_desktop uid)
wait_healthy "$name" 90
"$RUNTIME" logs "$name" 2>&1 | grep -q "desktop ready" || fail "no 'desktop ready' log line"
pass
```

`tests/cases/no-root-processes.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
name=$(start_desktop noroot)
wait_healthy "$name" 90
uids=$(exec_in "$name" sh -c 'cat /proc/[0-9]*/status 2>/dev/null | awk "/^Uid:/ {print \$2}" | sort -u')
[ "$uids" = 123456 ] || fail "unexpected process uids: $(echo $uids)"
pass
```

`tests/cases/tls.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT

fp() { exec_in "$1" openssl x509 -in /run/desktop/tls/tls.crt -noout -fingerprint -sha256; }
a=$(start_desktop tls-a)
b=$(start_desktop tls-b)
wait_healthy "$a"
wait_healthy "$b"
[ "$(fp "$a")" != "$(fp "$b")" ] || fail "two containers share a TLS certificate"

mkdir "$dir/full" "$dir/partial"
"$RUNTIME" run --rm --user "$(id -u):$(id -g)" -v "$dir/full:/out" --entrypoint openssl "$IMAGE" \
    req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mounted -keyout /out/tls.key -out /out/tls.crt 2>/dev/null
cp "$dir/full/tls.crt" "$dir/partial/tls.crt"
chmod -R a+rX "$dir"

m=$(start_desktop tls-mounted -v "$dir/full:/etc/desktop/tls:ro")
wait_healthy "$m"
"$RUNTIME" logs "$m" 2>&1 | grep -q "using mounted TLS certificate /etc/desktop/tls/tls.crt" || fail "mounted cert not used"

p=$(start_desktop tls-partial -v "$dir/partial:/etc/desktop/tls:ro")
code=$(wait_exit "$p" 60)
[ "$code" != 0 ] || fail "started with only tls.crt mounted"
"$RUNTIME" logs "$p" 2>&1 | grep -q "both tls.crt and tls.key" || fail "unclear error for partial TLS mount"
pass
```

`tests/cases/listen-address.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

d=$(start_desktop listen-default)
wait_healthy "$d"
listening_on "$d" 0100007F:0D3D || fail "not listening on 127.0.0.1:3389"
! listening_on "$d" 00000000:0D3D || fail "listening on 0.0.0.0:3389 by default"

w=$(start_desktop listen-any -e RDP_LISTEN_ADDRESS=0.0.0.0)
wait_healthy "$w"
listening_on "$w" 00000000:0D3D || fail "RDP_LISTEN_ADDRESS=0.0.0.0 not honoured"

i=$(start_desktop listen-bad -e RDP_LISTEN_ADDRESS=localhost)
code=$(wait_exit "$i" 30)
[ "$code" != 0 ] || fail "accepted RDP_LISTEN_ADDRESS=localhost"
"$RUNTIME" logs "$i" 2>&1 | grep -q "RDP_LISTEN_ADDRESS must be an IPv4 address" || fail "unclear error for bad address"
pass
```

`tests/cases/lifecycle.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

# SIGTERM stops cleanly and quickly
s=$(start_desktop stop)
wait_healthy "$s"
start=$SECONDS
"$RUNTIME" stop -t 20 "$s" >/dev/null
[ $((SECONDS - start)) -lt 15 ] || fail "docker stop took $((SECONDS - start))s"
[ "$("$RUNTIME" inspect -f '{{.State.ExitCode}}' "$s")" = 0 ] || fail "non-zero exit after SIGTERM"

# A crashed component stops the container with a non-zero status
c=$(start_desktop crash)
wait_healthy "$c"
exec_in "$c" sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = Xorg ] && kill "${p#/proc/}"; done; true'
code=$(wait_exit "$c" 30)
[ "$code" != 0 ] || fail "container exited 0 after Xorg crashed"

# Restart without tmpfs keeps /tmp and /run/desktop in the container layer: must recover
r="dt-$$-restart"
"$RUNTIME" run -d --label "$TEST_LABEL" --name "$r" --user 123456:0 --shm-size 1g "$IMAGE" >/dev/null
wait_healthy "$r"
"$RUNTIME" restart -t 20 "$r" >/dev/null
wait_healthy "$r" 90
pass
```

- [ ] **Step 2: Run them to verify they fail**

```bash
docker build -t desktop:dev . && tests/run desktop:dev tests/cases/arbitrary-uid.sh tests/cases/listen-address.sh
```

Expected: FAIL with `desktop mode is not implemented yet` in the container logs.

- [ ] **Step 3: Implement TLS**

`rootfs/usr/local/lib/desktop/tls.sh`:

```bash
# shellcheck shell=bash
# TLS material for xrdp: a mounted kubernetes.io/tls pair, or a fresh self-signed pair per start.

setup_tls() {
    local mounted=/etc/desktop/tls generated="$DESKTOP_RUNTIME_DIR/tls"
    if [ -e "$mounted/tls.crt" ] || [ -e "$mounted/tls.key" ]; then
        [ -r "$mounted/tls.crt" ] && [ -r "$mounted/tls.key" ] \
            || die "$mounted must contain both tls.crt and tls.key, readable by uid $(id -u)"
        TLS_CERT="$mounted/tls.crt"
        TLS_KEY="$mounted/tls.key"
        log "using mounted TLS certificate $TLS_CERT"
    else
        TLS_CERT="$generated/tls.crt"
        TLS_KEY="$generated/tls.key"
        (umask 077 && openssl req -x509 -newkey rsa:3072 -nodes -days 825 \
            -subj "/CN=docker-remote-desktop" -keyout "$TLS_KEY" -out "$TLS_CERT" 2>/dev/null) \
            || die "failed to generate a TLS certificate in $generated"
        log "generated TLS certificate, $(openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256)"
    fi
    export TLS_CERT TLS_KEY
}
```

- [ ] **Step 4: Implement the configuration files**

`rootfs/etc/desktop/xrdp.ini.tmpl` (rendered with `envsubst`):

```ini
; Generated at container start by /usr/local/bin/desktop from /etc/desktop/xrdp.ini.tmpl
[Globals]
ini_version=1
fork=true
port=tcp://${RDP_LISTEN_ADDRESS}:3389
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=tls
crypt_level=high
certificate=${TLS_CERT}
key_file=${TLS_KEY}
ssl_protocols=TLSv1.2, TLSv1.3
autorun=Desktop
allow_channels=true
allow_multimon=true
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
max_bpp=32
new_cursors=true
use_fastpath=both

[Logging]
LogFile=${DESKTOP_RUNTIME_DIR}/log/xrdp.log
LogLevel=INFO
EnableConsole=true
ConsoleLevel=INFO
EnableSyslog=false

[Channels]
rdpdr=false
rdpsnd=true
drdynvc=true
cliprdr=true
rail=false
xrdpvr=false
tcutils=false

; Direct connection to the already running Xorg session: no sesman, no PAM, no root.
[Desktop]
name=Desktop
lib=libxup.so
username=na
password=na
ip=127.0.0.1
port=/run/xrdp/sockdir/xrdp_display_10
chansrvport=DISPLAY(10)
code=20
```

`rootfs/etc/desktop/pulse/default.pa`:

```
# PulseAudio configuration for the desktop session: audio goes to the RDP client via xrdp-chansrv.
.fail
load-module module-native-protocol-unix
load-module module-xrdp-sink
load-module module-xrdp-source
set-default-sink xrdp-sink
set-default-source xrdp-source
```

`rootfs/etc/xrdp/sesman.ini`:

```ini
; Read by xrdp-chansrv only; sesman is not used in this image.
[Security]
RestrictOutboundClipboard=none
RestrictInboundClipboard=none

[Chansrv]
EnableFuseMount=false

[ChansrvLogging]
LogLevel=INFO
EnableSyslog=false
EnableConsole=false
```

- [ ] **Step 5: Implement the session supervisor**

`rootfs/usr/local/lib/desktop/session.sh`:

```bash
# shellcheck shell=bash
# Starts and supervises the desktop session components as the current (unprivileged) user.

DESKTOP_DISPLAY=10
XRDP_SOCKET_DIR=/run/xrdp/sockdir
COMPONENT_PIDS=()

validate_config() {
    RDP_LISTEN_ADDRESS=${RDP_LISTEN_ADDRESS:-127.0.0.1}
    [[ "$RDP_LISTEN_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "RDP_LISTEN_ADDRESS must be an IPv4 address (got '$RDP_LISTEN_ADDRESS')"
    export RDP_LISTEN_ADDRESS
}

# Leftovers from a previous run when /tmp or /run/desktop survive a container restart.
clean_stale_state() {
    rm -f "/tmp/.X${DESKTOP_DISPLAY}-lock" "/tmp/.X11-unix/X${DESKTOP_DISPLAY}" \
        "$DESKTOP_RUNTIME_DIR/xrdp/xrdp.pid" "$XRDP_SOCKET_DIR"/*
    rm -rf "$XDG_RUNTIME_DIR/pulse"
    unset XRDP_SESMAN_MAX_IDLE_TIME XRDP_SESMAN_MAX_DISC_TIME XRDP_SESMAN_KILL_DISCONNECTED
}

start_component() {
    local name=$1
    shift
    log "starting $name"
    "$@" &
    COMPONENT_PIDS+=("$!")
}

wait_for() {
    local what=$1 timeout=$2 i
    shift 2
    for ((i = 0; i < timeout * 10; i++)); do
        "$@" 2>/dev/null && return 0
        sleep 0.1
    done
    die "timed out after ${timeout}s waiting for $what"
}

rdp_port_open() {
    local addr=$RDP_LISTEN_ADDRESS
    [ "$addr" != 0.0.0.0 ] || addr=127.0.0.1
    (exec 3<>"/dev/tcp/$addr/3389") 2>/dev/null
}

start_xorg() {
    start_component Xorg env XRDP_SOCKET_PATH="$XRDP_SOCKET_DIR" /usr/lib/xorg/Xorg ":$DESKTOP_DISPLAY" \
        -config xrdp/xorg.conf -noreset -nolisten tcp -logfile "$DESKTOP_RUNTIME_DIR/log/Xorg.log"
    wait_for "the Xorg socket" 30 test -S "$XRDP_SOCKET_DIR/xrdp_display_$DESKTOP_DISPLAY"
    export DISPLAY=":$DESKTOP_DISPLAY"
}

start_chansrv() {
    start_component xrdp-chansrv env CHANSRV_LOG_PATH="$DESKTOP_RUNTIME_DIR/log" /usr/sbin/xrdp-chansrv
    wait_for "the chansrv socket" 30 test -S "$XRDP_SOCKET_DIR/xrdp_chansrv_socket_$DESKTOP_DISPLAY"
}

start_pulseaudio() {
    start_component pulseaudio env XRDP_SOCKET_PATH="$XRDP_SOCKET_DIR" pulseaudio -n \
        -F /etc/desktop/pulse/default.pa --daemonize=no --exit-idle-time=-1 --log-target=stderr
    wait_for "the PulseAudio socket" 30 test -S "$XDG_RUNTIME_DIR/pulse/native"
}

start_xfce() {
    start_component xfce dbus-launch --exit-with-session startxfce4
}

start_xrdp() {
    envsubst '${RDP_LISTEN_ADDRESS} ${TLS_CERT} ${TLS_KEY} ${DESKTOP_RUNTIME_DIR}' \
        < /etc/desktop/xrdp.ini.tmpl > "$DESKTOP_RUNTIME_DIR/xrdp.ini"
    start_component xrdp /usr/sbin/xrdp --nodaemon --config "$DESKTOP_RUNTIME_DIR/xrdp.ini"
    wait_for "xrdp on $RDP_LISTEN_ADDRESS:3389" 30 rdp_port_open
}

stop_components() {
    local pid alive _
    for pid in "${COMPONENT_PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for _ in $(seq 100); do
        alive=0
        for pid in "${COMPONENT_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" = 1 ] || return 0
        sleep 0.1
    done
    for pid in "${COMPONENT_PIDS[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
}

supervise() {
    trap 'log "termination requested"; stop_components; exit 0' TERM INT
    local rc=0
    wait -n "${COMPONENT_PIDS[@]}" || rc=$?
    log "a desktop component exited (status $rc); stopping the others"
    stop_components
    exit 1
}

healthcheck() {
    RDP_LISTEN_ADDRESS=${RDP_LISTEN_ADDRESS:-127.0.0.1}
    if ! [ -S "$XRDP_SOCKET_DIR/xrdp_display_$DESKTOP_DISPLAY" ]; then
        echo "unhealthy: Xorg socket missing" >&2
        return 1
    fi
    if ! rdp_port_open; then
        echo "unhealthy: xrdp not accepting connections on port 3389" >&2
        return 1
    fi
}
```

- [ ] **Step 6: Wire desktop mode into the entrypoint**

Replace `rootfs/usr/local/bin/desktop` with:

```bash
#!/usr/bin/env bash
# Container entrypoint: `desktop` starts the RDP desktop, `desktop CMD...` runs CMD as the
# desktop user, `desktop healthcheck` is the liveness/startup probe.
set -Eeuo pipefail
source /usr/local/lib/desktop/common.sh
source /usr/local/lib/desktop/tls.sh
source /usr/local/lib/desktop/session.sh
trap 'die "command failed (${BASH_SOURCE[0]}:${LINENO}): ${BASH_COMMAND}"' ERR

main() {
    if [ "${1:-}" = healthcheck ]; then
        if healthcheck; then exit 0; else exit 1; fi
    fi

    setup_runtime_dirs
    setup_identity
    if [ $# -gt 0 ]; then
        run_init_hooks
        exec "$@"
    fi

    validate_config
    clean_stale_state
    setup_tls
    run_init_hooks
    start_xorg
    start_chansrv
    start_pulseaudio
    start_xfce
    start_xrdp
    log "desktop ready: RDP listening on $RDP_LISTEN_ADDRESS:3389"
    supervise
}

main "$@"
```

- [ ] **Step 7: Add the PulseAudio module build and the desktop packages to the Dockerfile**

Replace the whole `Dockerfile` with:

```dockerfile
# syntax=docker/dockerfile:1

# Ubuntu archive snapshot for every apt operation; bumped weekly by .github/workflows/snapshot-bump.yml
ARG UBUNTU_SNAPSHOT=20261001T000000Z

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS base
ARG UBUNTU_SNAPSHOT
COPY --chmod=0755 build/apt-snapshot /usr/local/sbin/apt-snapshot
RUN apt-snapshot "${UBUNTU_SNAPSHOT}"

FROM base AS pulse-builder
# renovate: datasource=github-tags depName=neutrinolabs/pulseaudio-module-xrdp
ARG PULSE_XRDP_VERSION=v0.8
ARG PULSE_XRDP_COMMIT=f36911ee49a85dce19ecc3d53b0edaee624c9faa
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      autoconf build-essential dpkg-dev git libltdl-dev libpulse-dev libtool lsb-release sudo \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${PULSE_XRDP_VERSION}" https://github.com/neutrinolabs/pulseaudio-module-xrdp.git /src \
 && test "$(git -C /src rev-parse HEAD)" = "${PULSE_XRDP_COMMIT}"
WORKDIR /src
RUN scripts/install_pulseaudio_sources_apt.sh \
 && ./bootstrap \
 && ./configure PULSE_DIR="${HOME}/pulseaudio.src" \
 && make \
 && make install DESTDIR=/tmp/install \
 && mkdir /out \
 && find /tmp/install -name 'module-xrdp-*.so' -exec cp {} /out/ \; \
 && test -f /out/module-xrdp-sink.so && test -f /out/module-xrdp-source.so

FROM base
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      dbus-x11 gettext-base libnss-wrapper locales openssl pavucontrol pulseaudio pulseaudio-utils tini tzdata \
      x11-xserver-utils xfce4 xfce4-pulseaudio-plugin xfce4-terminal xorgxrdp xrdp xubuntu-icon-theme \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8
COPY --from=pulse-builder /out/ /tmp/pulse-modules/
RUN moddir="$(dirname "$(dpkg -L pulseaudio | grep -m1 '/modules/module-null-sink.so$')")" \
 && install -m 0644 /tmp/pulse-modules/module-xrdp-*.so "${moddir}/" \
 && rm -rf /tmp/pulse-modules
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/desktop \
 && chmod 0644 /usr/local/lib/desktop/*.sh \
 && deluser --remove-home ubuntu \
 && useradd --uid 1001 --gid 0 --home-dir /home/wineuser --no-create-home --shell /bin/bash wineuser \
 && rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem /etc/xrdp/rsakeys.ini \
          /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem \
 && rm -rf /run/xrdp && ln -s /run/desktop/xrdp /run/xrdp \
 && mkdir -p /home/wineuser /run/desktop /etc/desktop/init.d \
 && chgrp -R 0 /home/wineuser /run/desktop \
 && chmod -R g=u /home/wineuser /run/desktop \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
ENV LANG=en_US.UTF-8 HOME=/home/wineuser
USER 1001
WORKDIR /home/wineuser
EXPOSE 3389/tcp
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/desktop"]
```

If Task 1 recorded "read-only root: unsupported", add `&& install -d -g 0 -m 0775 /var/lib/xkb \` before the `find` line.

- [ ] **Step 8: Run all tests to verify they pass**

```bash
docker build -t desktop:dev . && tests/run desktop:dev
```

Expected: every case PASSes, ending with `all 10 test cases passed`.

- [ ] **Step 9: Commit**

```bash
git add -A Dockerfile rootfs tests
git commit -m "feat: rootless xrdp desktop session with per-start TLS, audio and clipboard" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: End-to-end RDP test (connect, audio channel, reconnect)

**Files:**
- Create: `tests/rdp-client/Dockerfile`, `tests/cases/rdp-e2e.sh`

**Interfaces:**
- Consumes: `build_rdp_client`, `start_desktop`, `wait_healthy`, `poll`, `exec_in` from `tests/lib.sh`, and the socket paths from Global Constraints.
- Produces: `desktop-test-rdp-client`, which Plan 2's kind test also uses as the RDP client.

- [ ] **Step 1: Write the client image and the failing test**

`tests/rdp-client/Dockerfile` (build context: repo root):

```dockerfile
# syntax=docker/dockerfile:1
# RDP client used by tests/cases/rdp-e2e.sh (FreeRDP under Xvfb).
ARG UBUNTU_SNAPSHOT=20261001T000000Z
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG UBUNTU_SNAPSHOT
COPY --chmod=0755 build/apt-snapshot /usr/local/sbin/apt-snapshot
RUN apt-snapshot "${UBUNTU_SNAPSHOT}" \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends freerdp2-x11 xauth xvfb \
 && rm -rf /var/lib/apt/lists/*
```

`tests/cases/rdp-e2e.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

client_image=$(build_rdp_client)
name=$(start_desktop e2e)
wait_healthy "$name" 90

connect() {
    "$RUNTIME" run -d --label "$TEST_LABEL" --name "$name-client-$1" --network "container:$name" "$client_image" \
        xvfb-run -a xfreerdp /v:127.0.0.1:3389 /cert:ignore /sec:tls /u:wineuser /p:unused \
        /sound:sys:fake +clipboard >/dev/null
}
connections() { exec_in "$name" grep -c 'connected to X11rdp_pid' /run/desktop/log/xrdp.log || true; }
xorg_pid() { exec_in "$name" sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = Xorg ] && echo "${p#/proc/}"; done'; }

before=$(xorg_pid)
connect 1
poll 30 "first RDP session" sh -c "[ \"\$($RUNTIME exec $name grep -c 'connected to X11rdp_pid' /run/desktop/log/xrdp.log)\" -ge 1 ]"
poll 30 "audio channel" exec_in "$name" test -S /run/xrdp/sockdir/xrdp_chansrv_audio_out_socket_10
exec_in "$name" env XDG_RUNTIME_DIR=/run/desktop/xdg pactl list short sinks | grep -q xrdp-sink \
    || fail "xrdp-sink not present in PulseAudio"

"$RUNTIME" rm -f "$name-client-1" >/dev/null
connect 2
poll 30 "reconnection" sh -c "[ \"\$($RUNTIME exec $name grep -c 'connected to X11rdp_pid' /run/desktop/log/xrdp.log)\" -ge 2 ]"
[ "$(xorg_pid)" = "$before" ] || fail "reconnect started a new Xorg (session not resumed)"
exec_in "$name" /usr/local/bin/desktop healthcheck >/dev/null || fail "unhealthy after reconnect"
pass "connected=$(connections)"
```

- [ ] **Step 2: Run it and verify it passes**

This test is written after the implementation, so it should pass immediately. Make it fail once to prove it detects problems: temporarily change `rdpsnd=true` to `rdpsnd=false` in `rootfs/etc/desktop/xrdp.ini.tmpl` and run:

```bash
docker build -t desktop:dev . && tests/run desktop:dev tests/cases/rdp-e2e.sh
```

Expected: `FAIL [rdp-e2e]: timed out after 30s waiting for audio channel`.

Then restore `rdpsnd=true`, rebuild and rerun. Expected: `PASS [rdp-e2e]: connected=2`.

- [ ] **Step 3: Commit**

```bash
git add tests/rdp-client tests/cases/rdp-e2e.sh
git commit -m "test: end-to-end RDP connect, audio channel and session resume" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Helper scripts and README

**Files:**
- Modify: `build`, `run`, `start`, `stop`, `README.md`

**Interfaces:**
- Produces:
  - `./build [docker build args]`, which tags `docker-remote-desktop:local`.
  - `./run`: interactive, hardened, published on `127.0.0.1:3389`.
  - `./start` and `./stop`: detached.

- [ ] **Step 1: Rewrite the helper scripts**

`build`:

```bash
#!/usr/bin/env bash
# Build the image locally as docker-remote-desktop:local
set -euo pipefail
cd "$(dirname "$0")"
docker build "$@" -t docker-remote-desktop:local .
```

`start`:

```bash
#!/usr/bin/env bash
# Start the desktop in the background, reachable only from this machine on 127.0.0.1:3389
set -euo pipefail
docker run -d --rm --name remote-desktop \
    --user 1001:0 --cap-drop ALL --security-opt no-new-privileges --read-only \
    --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --shm-size 1g \
    -v remote-desktop-home:/home/wineuser -e RDP_LISTEN_ADDRESS=0.0.0.0 \
    -p 127.0.0.1:3389:3389 "${IMAGE:-docker-remote-desktop:local}"
echo "Connect an RDP client to 127.0.0.1:3389"
```

`run` (the same, interactive, with a shell instead of the desktop):

```bash
#!/usr/bin/env bash
# Run an interactive shell in the image as the desktop user (command mode)
set -euo pipefail
docker run -it --rm \
    --user 1001:0 --cap-drop ALL --security-opt no-new-privileges --read-only \
    --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --shm-size 1g \
    -v remote-desktop-home:/home/wineuser "${IMAGE:-docker-remote-desktop:local}" /bin/bash
```

`stop`:

```bash
#!/usr/bin/env bash
set -euo pipefail
docker stop remote-desktop
```

- [ ] **Step 2: Rewrite `README.md`**

The README must contain these sections:
1. **What it is:** a rootless XFCE desktop over RDP; audio and clipboard; drive redirection disabled; no login password.
2. **Security model:** access control is network reachability. xrdp binds to `127.0.0.1` by default. Local mode is for single-user workstations. On OpenShift, `pods/portforward` RBAC is the boundary.
3. **Quick start:** `./build`, `./start`, connect to `127.0.0.1:3389`, `./stop`.
4. **Configuration:** `RDP_LISTEN_ADDRESS`, `TZ`, mounting `/etc/desktop/tls/{tls.crt,tls.key}`.
5. **Extending:** using it as a base image; the `/etc/desktop/init.d/*.sh` hook contract (copied from the Task 3 Interfaces block); don't override `ENTRYPOINT`; `USER 1001`, group 0; write only to `/home/wineuser`, `/run/desktop` and `/tmp`.
6. **Testing:** `tests/run IMAGE [CASE...]`.
7. **Dependency updates:** Renovate plus the weekly Ubuntu snapshot PR.
8. **Breaking changes from upstream:** the `ubuntu` user and password are gone; Firefox is gone; the image runs as UID 1001; the published image is on GHCR.

- [ ] **Step 3: Smoke test the scripts**

```bash
./build -q && ./start && sleep 20 && docker exec remote-desktop desktop healthcheck && ./stop
```

Expected: the image ID, the container ID, `Connect an RDP client to 127.0.0.1:3389`, then the healthcheck exits 0 (no output) and `remote-desktop` is printed.

- [ ] **Step 4: Commit**

```bash
git add build run start stop README.md
git commit -m "docs: hardened helper scripts and README for the rootless image" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: CI pipeline (build once → test → scan → push → attest → sign)

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `ghcr.io/kamphaus/docker-remote-desktop:noble-<YYYYMMDD>-<sha7>` and `:noble`. The digest is written to the job summary. Plan 2 consumes this image by digest.

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  IMAGE_NAME: ghcr.io/kamphaus/docker-remote-desktop
  TRIVY_IMAGE: aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa

jobs:
  build-test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
      - name: Build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          load: true
          tags: desktop:ci
      - name: Test
        run: tests/run desktop:ci
      - name: Scan
        run: >-
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE"
          image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 desktop:ci
      - name: Save tested image
        if: github.ref == 'refs/heads/master' && github.event_name != 'pull_request'
        run: docker save desktop:ci | gzip > image.tar.gz
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        if: github.ref == 'refs/heads/master' && github.event_name != 'pull_request'
        with:
          name: image
          path: image.tar.gz
          retention-days: 1

  publish:
    needs: build-test
    if: github.ref == 'refs/heads/master' && github.event_name != 'pull_request'
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: image
      - name: Load and tag
        id: tag
        run: |
          gunzip -c image.tar.gz | docker load
          version="noble-$(date -u +%Y%m%d)-${GITHUB_SHA::7}"
          docker tag desktop:ci "$IMAGE_NAME:$version"
          docker tag desktop:ci "$IMAGE_NAME:noble"
          echo "version=$version" >> "$GITHUB_OUTPUT"
      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Push
        id: push
        env:
          VERSION: ${{ steps.tag.outputs.version }}
        run: |
          docker push "$IMAGE_NAME:$VERSION"
          docker push "$IMAGE_NAME:noble"
          digest=$(docker buildx imagetools inspect "$IMAGE_NAME:$VERSION" --format '{{json .Manifest.Digest}}' | tr -d '"')
          echo "digest=$digest" >> "$GITHUB_OUTPUT"
          echo "Published \`$IMAGE_NAME:$VERSION@$digest\`" >> "$GITHUB_STEP_SUMMARY"
      - name: Generate SBOM
        env:
          VERSION: ${{ steps.tag.outputs.version }}
        run: >-
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:/out" "$TRIVY_IMAGE"
          image --format spdx-json --output /out/sbom.spdx.json "$IMAGE_NAME:$VERSION"
      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
        with:
          subject-name: ${{ env.IMAGE_NAME }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
      - uses: actions/attest-sbom@c604332985a26aa8cf1bdc465b92731239ec6b9e # v4.1.0
        with:
          subject-name: ${{ env.IMAGE_NAME }}
          subject-digest: ${{ steps.push.outputs.digest }}
          sbom-path: sbom.spdx.json
          push-to-registry: true
      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
      - name: Sign and verify
        env:
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          cosign sign --yes "$IMAGE_NAME@$DIGEST"
          cosign verify "$IMAGE_NAME@$DIGEST" \
            --certificate-identity "https://github.com/${GITHUB_REPOSITORY}/.github/workflows/ci.yml@refs/heads/master" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null
```

- [ ] **Step 2: Lint the workflow locally**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

Expected: no output and exit code 0. `actionlint` is run unpinned here only as a local, throwaway check; it is not part of CI.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build once, test, scan, then push, attest and sign the tested image" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Renovate configuration and weekly snapshot bump

**Files:**
- Create: `renovate.json`, `.github/workflows/snapshot-bump.yml`

**Interfaces:**
- Consumes: the `# renovate:` annotation above `ARG PULSE_XRDP_VERSION` and `ARG PULSE_XRDP_COMMIT` (Task 4), the `FROM …@sha256` lines, and the action SHA pins.
- Produces: weekly PRs; `ci.yml` dispatched on the snapshot PR branch.

- [ ] **Step 1: Write `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "docker:pinDigests",
    "helpers:pinGitHubActionDigests",
    ":semanticCommits"
  ],
  "schedule": ["before 6am on monday"],
  "labels": ["dependencies"],
  "vulnerabilityAlerts": { "enabled": true },
  "customManagers": [
    {
      "customType": "regex",
      "description": "ARG pins annotated with '# renovate:' (optionally followed by a matching _COMMIT pin)",
      "managerFilePatterns": ["/(^|/)Dockerfile$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)(?: registryUrl=(?<registryUrl>\\S+))?(?: versioning=(?<versioning>\\S+))?\\s+ARG \\w+_VERSION=(?<currentValue>\\S+)(?:\\s+ARG \\w+_COMMIT=(?<currentDigest>[0-9a-f]{40}))?"
      ],
      "versioningTemplate": "{{#if versioning}}{{{versioning}}}{{else}}semver-coerced{{/if}}"
    }
  ],
  "packageRules": [
    {
      "matchManagers": ["github-actions"],
      "groupName": "GitHub Actions"
    },
    {
      "matchUpdateTypes": ["digest", "pinDigest"],
      "automerge": true
    },
    {
      "matchUpdateTypes": ["major"],
      "automerge": false
    }
  ]
}
```

- [ ] **Step 2: Validate the config**

```bash
docker run --rm -v "$PWD/renovate.json:/renovate.json:ro" --entrypoint renovate-config-validator renovate/renovate:latest /renovate.json
```

Expected: `Config validated successfully`. The unpinned validator image is a local, throwaway check only.

- [ ] **Step 3: Write `.github/workflows/snapshot-bump.yml`**

```yaml
name: snapshot-bump

on:
  schedule:
    - cron: '0 4 * * 1'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  bump:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      pull-requests: write
      actions: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Update UBUNTU_SNAPSHOT
        id: bump
        run: |
          snapshot="$(date -u +%Y%m%d)T000000Z"
          grep -rl --include=Dockerfile '^ARG UBUNTU_SNAPSHOT=' . \
            | xargs sed -i -E "s/^ARG UBUNTU_SNAPSHOT=.*/ARG UBUNTU_SNAPSHOT=${snapshot}/"
          echo "snapshot=$snapshot" >> "$GITHUB_OUTPUT"
      - name: Open pull request
        env:
          GH_TOKEN: ${{ github.token }}
          SNAPSHOT: ${{ steps.bump.outputs.snapshot }}
        run: |
          if git diff --quiet; then
            echo "snapshot already at $SNAPSHOT"
            exit 0
          fi
          branch="snapshot-bump/$SNAPSHOT"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git switch -c "$branch"
          git commit -am "build(deps): bump Ubuntu snapshot to $SNAPSHOT"
          git push --force origin "$branch"
          gh label create dependencies --force --color 0366d6
          gh pr create --base master --head "$branch" --label dependencies \
            --title "build(deps): bump Ubuntu snapshot to $SNAPSHOT" \
            --body "Weekly Ubuntu archive snapshot bump. Merging this PR is how Ubuntu security fixes reach the image."
          # PRs created with GITHUB_TOKEN do not trigger pull_request workflows: dispatch CI explicitly.
          gh workflow run ci.yml --ref "$branch"
```

- [ ] **Step 4: Lint and commit**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
git add renovate.json .github/workflows/snapshot-bump.yml
git commit -m "build: Renovate config and weekly Ubuntu snapshot bump" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: actionlint prints nothing.

---

### Task 9: Publish and hand over to Plan 2 (outward-facing: confirm with the user first)

**Files:** none.

**Interfaces:**
- Produces: a public `ghcr.io/kamphaus/docker-remote-desktop` package with a signed digest. Plan 2, Task 2 reads it with `docker buildx imagetools inspect ghcr.io/kamphaus/docker-remote-desktop:noble`.

- [ ] **Step 1: Run the full suite one last time**

```bash
docker build -t desktop:dev . && tests/run desktop:dev
```

Expected: `all 11 test cases passed`.

- [ ] **Step 2: Push and open the PR (ask the user first)**

```bash
git push -u origin feat/rootless-desktop
gh pr create --base master --title "Rootless, pinned, OpenShift-compatible desktop image" \
  --body "Implements Plan 1 of docs/superpowers/specs/2026-10-11-rootless-openshift-design.md (docker-wine repo)."
```

Expected: the PR URL is printed, and the `ci / build-test` check passes on the PR.

- [ ] **Step 3: GitHub settings (the user does these in the web UI; list them for the user)**

1. Settings → Actions → General → Workflow permissions: enable **"Allow GitHub Actions to create and approve pull requests"** (needed by `snapshot-bump.yml`).
2. Install the Mend Renovate GitHub App on `kamphaus/docker-remote-desktop`.
3. Branch protection on `master`: require `ci / build-test` (needed for Renovate automerge to be safe).

- [ ] **Step 4: After merge, make the package public and record the digest**

The user does this in the web UI: Package settings → Change visibility → Public. Then run:

```bash
docker buildx imagetools inspect ghcr.io/kamphaus/docker-remote-desktop:noble --format '{{json .Manifest.Digest}}'
```

Expected: a quoted `sha256:` digest that matches the one in the `publish` job summary.
