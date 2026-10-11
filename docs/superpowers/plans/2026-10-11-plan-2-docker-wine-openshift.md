# Plan 2: docker-wine on the rootless base, OpenShift deployment and derived images

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `kamphaus/docker-wine` on top of the rootless base image from Plan 1. The result has pinned Wine, winetricks and add-ons; a `wine-prefix` tool with seed and ephemeral prefix modes; `run-local`; an OpenShift Kustomize deployment reached through `oc port-forward`; a reusable workflow for derived images; and Renovate automation.

**Architecture:**
- The Wine image adds packages and three small tools to the base image: `fetch-verified`, `wine-prefix` and the `50-wine-prefix.sh` init hook.
- Derived images install software into a template prefix at `/opt/wine/prefix-template`. At startup the hook copies that template to a location owned by the runtime UID, because Wine refuses prefixes it doesn't own.
- The OpenShift manifests are plain Kustomize with no Service. They are validated with kubeconform and run end-to-end on kind with Pod Security `restricted`.

**Tech Stack:** Wine 11.0 (WineHQ noble packages), winetricks, bash, Docker/buildx, Kustomize (`kubectl kustomize`), kind, kubeconform, GitHub Actions, Renovate (Mend-hosted app), Trivy, cosign.

**Spec:** `docs/superpowers/specs/2026-10-11-rootless-openshift-design.md` in this repo, branch `design/rootless-openshift`. Read Section 0 (Revisions) first.

**Prerequisite:** Plan 1 is complete. `ghcr.io/kamphaus/docker-remote-desktop:noble` is public and signed.

## Global Constraints

- Repository: `/mnt/c/Users/cfree/Code/docker-wine-rdp/docker-wine`, branch `feat/rootless-wine`, created from `master`. The spec and plans live on `design/rootless-openshift`; merge that branch into `feat/rootless-wine` first so they travel with the code.
- Every commit message ends with the trailer `Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not add a `Co-Authored-By` trailer.
- Pushing, opening PRs, changing GitHub settings and publishing packages are outward-facing. Confirm with the user before each one.
- Keep LF line endings (`.gitattributes`). The Dockerfile sets file modes explicitly.
- Base image: `ARG BASE_IMAGE=ghcr.io/kamphaus/docker-remote-desktop:noble@sha256:<digest>`, using the digest recorded in Plan 1 Task 9. For local development before publication, pass `--build-arg BASE_IMAGE=docker-remote-desktop:local`.
- What the base image provides (Plan 1):
  - `desktop` entrypoint: no arguments starts the desktop, arguments run command mode, `healthcheck` is the probe.
  - `/etc/desktop/init.d/*.sh` hooks are *sourced* in both modes, with `log`/`die` available. Exported variables reach the session or the command.
  - `USER 1001`, group 0, `HOME=/home/wineuser`. Writable paths: `/home/wineuser`, `/run/desktop`, `/tmp`.
  - `/usr/local/sbin/apt-snapshot`, with apt sources already pinned to the base image's snapshot.
- Wine: `ARG WINE_VERSION=11.0.0.0~noble-1`, which corresponds to upstream `wine-11.0`. WineHQ key fingerprint: `D43F640145369C51D786DDEA76F1A20FF987672F`.
- winetricks: tag `20260125`, commit `b76e1ee79ac57d7aceb384f74518fc423265810c`. The `src/winetricks` file at that commit has sha256 `431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b`.
- Add-ons for wine-11.0: Gecko `2.47.4` (x86 `26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6`, x86_64 `e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f`) and Mono `10.4.1` (x86 `071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23`).
- Notepad++ example: `8.9.8.1`, `npp.8.9.8.1.Installer.x64.exe`, sha256 `26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da`.
- Prefix paths:
  - Template: `/opt/wine/prefix-template`.
  - Seed mode: `$HOME/.wine`, with `$HOME/.wine.partial` as the copy target and `$HOME/.wine.bak-<old>` as the reseed backup.
  - Ephemeral mode: `/run/wine-prefix`.
  - The version file is `.prefix-version` inside the prefix.
- Environment: `PREFIX_MODE` = `seed` (default) or `ephemeral`; `PREFIX_UPGRADE` = `fail` (default), `reseed` or `keep`.
- Pinned GitHub Actions (same values as Plan 1, plus kind):

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
  | `helm/kind-action` | v1.15.1 | `1544676c07bb3570fcb70166beaa07c4528fd4aa` (kind `v0.33.0`) |

- Trivy: `aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa`.
- kubeconform: `ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e`.
- In CI, `setup-buildx-action` must use `driver: docker` so that test fixtures can be built `FROM` the locally loaded image.
- **Read-only root contingency:** if spec §3.4 "M0 results" says "read-only root: unsupported", remove `--read-only` from `HARDENED_BASE` in `tests/lib.sh` and from `run-local`, and set `readOnlyRootFilesystem: false` in the Deployment.

## Review Focus

These are the inputs and failure modes most likely to hurt a user that the spec's own tests don't cover. Each has a test in the task listed.

1. **Seed copy interrupted** (pod evicted mid-copy) leaving a half-copied prefix. Expected: the next start discards it and seeds cleanly, never treating a partial prefix as valid. *Task 3, `prefix-recovery.sh`.*
2. **A pre-migration `winehome` prefix owned by UID 1010.** Expected: a clear error naming the owner and the one-line migration command, not Wine's cryptic "not owned by you". *Task 3, `prefix-recovery.sh`.*
3. **Ephemeral mode on a read-only root without a volume at `/run/wine-prefix`.** Expected: a clear "not writable" error. *Task 3, `prefix-ephemeral.sh`.*
4. **A `downloads.lock` edited on Windows** (CRLF, comments, blank lines). Expected: parsed correctly. A non-HTTPS URL or a checksum mismatch is rejected and leaves no file behind. *Task 2, `fetch-verified.sh`.*
5. **`run-local` with an image that isn't pulled, or with a bad port.** Expected: a clear message and a non-zero exit, with no implicit pull. *Task 4, `run-local.sh`.*

---

### Task 1: Branch, cleanup, test harness and the Wine version helper

**Files:**
- Delete: `docker-wine`, `entrypoint.sh`, `entrypoint_ci_builder.sh`, `Dockerfile.build_from_source`, `build_from_source`, `deploy`, `hooks/`, `pulse-client.conf`, `download_gecko_and_mono.sh`, `.github/workflows/build.yml`, `.github/workflows/test.yml`
- Create: `.gitattributes`, `scripts/lib/wine-version.sh`, `tests/run`, `tests/lib.sh`, `tests/cases/wine-version-mapping.sh`
- Modify: `build`

**Interfaces:**
- Produces:
  - `upstream_wine_version PKG_VERSION`, which prints the upstream version (`11.0.0.0~noble-1` → `11.0`, `10.0.1.0~noble-1` → `10.0.1`).
  - `tests/lib.sh` with everything from Plan 1's harness, plus `HARDENED_BASE` (no home tmpfs), `run_home VOLUME [run-args...] IMAGE CMD...`, `new_volume SUFFIX` (prints the volume name), and `fixture_image PREFIX_VERSION` (prints the image tag).

- [ ] **Step 1: Branch and remove the obsolete files**

```bash
cd /mnt/c/Users/cfree/Code/docker-wine-rdp/docker-wine
git switch master && git switch -c feat/rootless-wine
git merge --no-ff design/rootless-openshift -m "Merge design docs" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
git rm -rq docker-wine entrypoint.sh entrypoint_ci_builder.sh Dockerfile.build_from_source build_from_source deploy hooks \
  pulse-client.conf download_gecko_and_mono.sh .github/workflows/build.yml .github/workflows/test.yml
printf '* text=auto eol=lf\n*.png binary\n*.asc text eol=lf\n' > .gitattributes
```

- [ ] **Step 2: Write the harness**

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
        "$REPO_ROOT/tests/fixtures/derived" >/dev/null
    echo "$tag"
}
```

- [ ] **Step 3: Write the failing test**

`tests/cases/wine-version-mapping.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
source "$REPO_ROOT/scripts/lib/wine-version.sh"

check() { [ "$(upstream_wine_version "$1")" = "$2" ] || fail "$1 -> $(upstream_wine_version "$1"), expected $2"; }
check '11.0.0.0~noble-1' 11.0
check '10.0.0.0~noble-1' 10.0
check '10.0.1.0~noble-1' 10.0.1
check '10.17.0.0~noble-1' 10.17
pass
```

- [ ] **Step 4: Run it to verify it fails**

```bash
tests/run unused tests/cases/wine-version-mapping.sh
```

Expected: FAIL, with `scripts/lib/wine-version.sh: No such file or directory`.

- [ ] **Step 5: Implement the helper and the build script**

`scripts/lib/wine-version.sh`:

```bash
# shellcheck shell=bash
# upstream_wine_version PKG_VERSION: WineHQ package version -> upstream release (git tag wine-<x>)
#   11.0.0.0~noble-1 -> 11.0 ; 10.0.1.0~noble-1 -> 10.0.1
upstream_wine_version() {
    local v=${1%%~*}
    while [[ "$v" == *.*.* && "$v" == *.0 ]]; do
        v=${v%.0}
    done
    printf '%s\n' "$v"
}
```

`build`:

```bash
#!/usr/bin/env bash
# Build the image locally as docker-wine:local (BASE_IMAGE defaults to the pinned GHCR digest).
#   BASE_IMAGE=docker-remote-desktop:local ./build   # use a locally built base
set -euo pipefail
cd "$(dirname "$0")"
args=()
[ -z "${BASE_IMAGE:-}" ] || args+=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
docker build "${args[@]}" "$@" -t docker-wine:local .
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
tests/run unused tests/cases/wine-version-mapping.sh
```

Expected: `PASS [wine-version-mapping]`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: remove launcher and legacy build paths, add test harness" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Wine image with pinned Wine, winetricks and verified add-ons

**Files:**
- Create: `winehq-archive.asc`, `addons.lock`, `rootfs/usr/local/bin/fetch-verified`, and test cases `tests/cases/fetch-verified.sh`, `tests/cases/wine-version.sh`, `tests/cases/addons-installed.sh`, `tests/cases/winetricks.sh`, `tests/cases/wine-arbitrary-uid.sh`
- Modify: `Dockerfile` (full rewrite)

**Interfaces:**
- Consumes: the base image (Global Constraints).
- Produces:
  - `fetch-verified LOCKFILE DESTDIR` on the image `PATH`. It exits non-zero on any problem and leaves no partial file behind. Lock format: `NAME VERSION URL sha256:HEX`, with `{version}` substituted in NAME and URL; `#` comments, blank lines and CRLF are tolerated.
  - `/opt/wine` and `/run/wine-prefix`, both `1001:0`, mode 0775.

- [ ] **Step 1: Write the failing tests**

`tests/cases/fetch-verified.sh`:

```bash
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
```

`tests/cases/wine-version.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
source "$REPO_ROOT/scripts/lib/wine-version.sh"

pkg=$(sed -n 's/^ARG WINE_VERSION=//p' "$REPO_ROOT/Dockerfile")
expected="wine-$(upstream_wine_version "$pkg")"
out=$(run_cmd "$IMAGE" wine --version)
[ "$out" = "$expected" ] || fail "wine --version is '$out', expected '$expected'"
pass "$out"
```

`tests/cases/addons-installed.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

gecko=$(awk '$1 ~ /^wine-gecko/ {print $2; exit}' "$REPO_ROOT/addons.lock")
run_cmd -e GECKO="$gecko" "$IMAGE" bash -c '
    p=${WINEPREFIX:-$HOME/.wine}
    xvfb-run -a wineboot -i >/dev/null 2>&1 && wineserver -w &&
    test -d "$p/drive_c/windows/system32/gecko/$GECKO" &&
    test -d "$p/drive_c/windows/syswow64/gecko/$GECKO" &&
    test -d "$p/drive_c/windows/mono/mono-2.0"' \
    || fail "Gecko $gecko (x86 + x86_64) or Mono not installed into a fresh prefix"
pass
```

`tests/cases/winetricks.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
run_cmd "$IMAGE" bash -c 'xvfb-run -a winetricks -q corefonts >/dev/null && test -f "${WINEPREFIX:-$HOME/.wine}/drive_c/windows/Fonts/arial.ttf"' \
    || fail "winetricks -q corefonts failed"
pass
```

`tests/cases/wine-arbitrary-uid.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
out=$(run_cmd "$IMAGE" bash -c 'xvfb-run -a wine cmd /c ver 2>/dev/null')
grep -q "Microsoft Windows" <<<"$out" || fail "wine cmd /c ver under uid 123456 printed: $out"
pass
```

- [ ] **Step 2: Run them to verify they fail**

```bash
BASE_IMAGE=docker-remote-desktop:local ./build -q
tests/run docker-wine:local tests/cases/fetch-verified.sh tests/cases/wine-version.sh
```

Expected: either the build fails (the old Dockerfile still references deleted files), or the cases FAIL.

- [ ] **Step 3: Add the WineHQ key and verify its fingerprint**

```bash
curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o winehq-archive.asc
gpg --show-keys --with-colons winehq-archive.asc | awk -F: '/^fpr/ {print $10; exit}'
```

Expected: `D43F640145369C51D786DDEA76F1A20FF987672F`. If it differs, stop and tell the user.

- [ ] **Step 4: Write `addons.lock` and `fetch-verified`**

`addons.lock`:

```
# Wine add-ons required by wine-11.0. Regenerate with: scripts/update-addons
wine-gecko-{version}-x86.msi 2.47.4 https://dl.winehq.org/wine/wine-gecko/{version}/wine-gecko-{version}-x86.msi sha256:26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6
wine-gecko-{version}-x86_64.msi 2.47.4 https://dl.winehq.org/wine/wine-gecko/{version}/wine-gecko-{version}-x86_64.msi sha256:e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f
wine-mono-{version}-x86.msi 10.4.1 https://dl.winehq.org/wine/wine-mono/{version}/wine-mono-{version}-x86.msi sha256:071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23
```

`rootfs/usr/local/bin/fetch-verified`:

```bash
#!/usr/bin/env bash
# Download every entry of a downloads.lock file over HTTPS and verify its SHA-256.
# Usage: fetch-verified LOCKFILE DESTDIR
# Lock format, one entry per line ('#' comments and blank lines are ignored):
#   NAME VERSION URL sha256:HEX        ({version} in NAME and URL is replaced by VERSION)
set -euo pipefail

die() { echo "fetch-verified: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: fetch-verified LOCKFILE DESTDIR"
lock=$1
dest=$2
[ -r "$lock" ] || die "cannot read $lock"
mkdir -p "$dest"

lineno=0
count=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r name version url checksum extra <<<"$line"
    [ -n "$checksum" ] && [ -z "$extra" ] || die "$lock:$lineno: expected 'NAME VERSION URL sha256:HEX'"
    name=${name//\{version\}/$version}
    url=${url//\{version\}/$version}
    [[ "$url" == https://* ]] || die "$lock:$lineno: only https:// URLs are allowed ($url)"
    [[ "$checksum" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$lock:$lineno: invalid checksum '$checksum'"
    [[ "$name" != */* && "$name" != .* ]] || die "$lock:$lineno: invalid file name '$name'"

    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$dest/$name.part" "$url" \
        || { rm -f "$dest/$name.part"; die "$lock:$lineno: download failed: $url"; }
    actual=$(sha256sum "$dest/$name.part" | cut -d' ' -f1)
    if [ "$actual" != "${checksum#sha256:}" ]; then
        rm -f "$dest/$name.part"
        die "$lock:$lineno: checksum mismatch for $name: expected ${checksum#sha256:}, got $actual"
    fi
    mv "$dest/$name.part" "$dest/$name"
    echo "fetch-verified: $name OK" >&2
    count=$((count + 1))
done < "$lock"

[ "$count" -gt 0 ] || die "$lock contains no entries"
```

- [ ] **Step 5: Write the Dockerfile**

Get the base digest:

```bash
docker buildx imagetools inspect ghcr.io/kamphaus/docker-remote-desktop:noble --format '{{json .Manifest.Digest}}'
```

Write `Dockerfile`, putting that digest into the first `ARG`:

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-remote-desktop:noble@sha256:<digest printed above>
FROM ${BASE_IMAGE}
USER 0

# renovate: datasource=deb depName=winehq-stable registryUrl=https://dl.winehq.org/wine-builds/ubuntu?suite=noble&components=main&binaryArch=amd64 versioning=deb
ARG WINE_VERSION=11.0.0.0~noble-1
COPY --chmod=0644 winehq-archive.asc /etc/apt/keyrings/winehq-archive.asc
RUN dpkg --add-architecture i386 \
 && printf '%s\n' 'Types: deb' 'URIs: https://dl.winehq.org/wine-builds/ubuntu' 'Suites: noble' 'Components: main' \
      'Architectures: amd64 i386' 'Signed-By: /etc/apt/keyrings/winehq-archive.asc' \
      > /etc/apt/sources.list.d/winehq.sources \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends \
      "winehq-stable=${WINE_VERSION}" "wine-stable=${WINE_VERSION}" \
      "wine-stable-amd64=${WINE_VERSION}" "wine-stable-i386:i386=${WINE_VERSION}" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      cabextract curl p7zip unzip winbind xauth xvfb \
 && rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-tags depName=Winetricks/winetricks
ARG WINETRICKS_VERSION=20260125
ARG WINETRICKS_COMMIT=b76e1ee79ac57d7aceb384f74518fc423265810c
ADD --chmod=0755 https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks /usr/local/bin/winetricks

COPY rootfs/ /
COPY addons.lock /tmp/addons.lock
RUN chmod 0755 /usr/local/bin/fetch-verified \
 && fetch-verified /tmp/addons.lock /tmp/addons \
 && install -d /usr/share/wine/gecko /usr/share/wine/mono \
 && mv /tmp/addons/wine-gecko-* /usr/share/wine/gecko/ \
 && mv /tmp/addons/wine-mono-* /usr/share/wine/mono/ \
 && rm -rf /tmp/addons /tmp/addons.lock \
 && install -d -o 1001 -g 0 -m 0775 /opt/wine /run/wine-prefix \
 && find / -xdev -perm /6000 -type f -exec chmod a-s {} +
ENV WINEARCH=win64
USER 1001
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
BASE_IMAGE=docker-remote-desktop:local ./build -q && tests/run docker-wine:local
```

Expected: all six cases PASS. `winetricks` needs network access.

- [ ] **Step 7: Commit**

```bash
git add -A Dockerfile winehq-archive.asc addons.lock rootfs tests .gitattributes
git commit -m "feat: Wine 11.0 on the rootless base with pinned winetricks and verified add-ons" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `wine-prefix` tool, prefix modes and the init hook

**Files:**
- Create: `rootfs/usr/local/bin/wine-prefix`, `rootfs/etc/desktop/init.d/50-wine-prefix.sh`, `tests/fixtures/derived/Dockerfile`, and test cases `tests/cases/prefix-seed.sh`, `tests/cases/prefix-upgrade.sh`, `tests/cases/prefix-ephemeral.sh`, `tests/cases/prefix-invalid.sh`, `tests/cases/prefix-recovery.sh`, `tests/cases/finalize-requires-version.sh`, `tests/cases/desktop-smoke.sh`
- Modify: `Dockerfile` (the `chmod` line in the `COPY rootfs/` step)

**Interfaces:**
- Consumes: `fetch-verified` and `/opt/wine` from Task 2; `log`/`die` and hook sourcing from the base image.
- Produces:
  - `wine-prefix run -- CMD...`: build time, uses the template prefix, runs under Xvfb.
  - `wine-prefix finalize`: requires `PREFIX_VERSION`.
  - `wine-prefix init`: prints the prefix path on stdout and logs to stderr.
  - The hook exports `WINEPREFIX` and logs `using Wine prefix <path> (PREFIX_MODE=<mode>)`.
  - Error strings that tests and docs depend on:
    - `prefix version <old> does not match image version <new>; set PREFIX_UPGRADE=reseed or keep`
    - `invalid PREFIX_MODE '<v>'; valid values: seed, ephemeral`
    - `invalid PREFIX_UPGRADE '<v>'; valid values: fail, reseed, keep`
    - `<path> is owned by uid <n>`
    - `<path> is not writable`
    - `PREFIX_VERSION must be set`

- [ ] **Step 1: Write the fixture and the failing tests**

`tests/fixtures/derived/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# Minimal derived image for the prefix tests: one registry key in the template prefix.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG PREFIX_VERSION
ENV PREFIX_VERSION=${PREFIX_VERSION}
RUN wine-prefix run -- wine reg add 'HKCU\Software\DesktopTest' /v Marker /d fixture /f \
 && wine-prefix finalize
```

`tests/cases/prefix-seed.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)
vol=$(new_volume seed)

out=$(run_home "$vol" "$img" bash -c 'echo "$WINEPREFIX"; cat "$WINEPREFIX/.prefix-version"' 2>/dev/null)
[ "$out" = $'/home/wineuser/.wine\n1' ] || fail "unexpected first start: $out"

out=$(run_home "$vol" "$img" true 2>&1)
! grep -q "copied template prefix" <<<"$out" || fail "prefix copied again on second start"

out=$(run_home "$vol" "$img" bash -c 'xvfb-run -a wine reg query "HKCU\\Software\\DesktopTest" /v Marker' 2>/dev/null)
grep -q fixture <<<"$out" || fail "template content missing from seeded prefix: $out"
pass
```

`tests/cases/prefix-upgrade.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
v1=$(fixture_image 1)
v2=$(fixture_image 2)
vol=$(new_volume upgrade)
run_home "$vol" "$v1" true 2>/dev/null

out=$(run_home "$vol" "$v2" true 2>&1) && fail "started with a mismatched prefix version"
grep -q "prefix version 1 does not match image version 2; set PREFIX_UPGRADE=reseed or keep" <<<"$out" \
    || fail "unexpected output: $out"

out=$(run_home "$vol" -e PREFIX_UPGRADE=keep "$v2" cat /home/wineuser/.wine/.prefix-version 2>&1)
grep -q "WARNING: keeping prefix version 1" <<<"$out" || fail "keep did not warn: $out"
[ "$(tail -n1 <<<"$out")" = 1 ] || fail "keep replaced the prefix: $out"

out=$(run_home "$vol" -e PREFIX_UPGRADE=reseed "$v2" bash -c 'cat ~/.wine/.prefix-version ~/.wine.bak-1/.prefix-version' 2>/dev/null)
[ "$out" = $'2\n1' ] || fail "reseed result: $out"
pass
```

`tests/cases/prefix-ephemeral.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

out=$(run_cmd -e PREFIX_MODE=ephemeral -v /run/wine-prefix "$img" bash -c \
    'echo "$WINEPREFIX"; cat "$WINEPREFIX/.prefix-version"; readlink "$WINEPREFIX/drive_c/users/wineuser/Documents"' 2>/dev/null)
[ "$out" = $'/run/wine-prefix\n1\n/home/wineuser/Documents' ] || fail "unexpected ephemeral prefix: $out"

out=$(run_cmd -e PREFIX_MODE=ephemeral "$img" true 2>&1) && fail "ephemeral mode started without a writable /run/wine-prefix"
grep -q "/run/wine-prefix is not writable" <<<"$out" || fail "unexpected output: $out"
pass
```

`tests/cases/prefix-invalid.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

out=$(run_cmd -e PREFIX_MODE=bogus "$img" true 2>&1) && fail "accepted PREFIX_MODE=bogus"
grep -q "invalid PREFIX_MODE 'bogus'; valid values: seed, ephemeral" <<<"$out" || fail "unexpected output: $out"

out=$(run_cmd -e PREFIX_UPGRADE=bogus "$img" true 2>&1) && fail "accepted PREFIX_UPGRADE=bogus"
grep -q "invalid PREFIX_UPGRADE 'bogus'; valid values: fail, reseed, keep" <<<"$out" || fail "unexpected output: $out"

# Plain docker-wine (no template): PREFIX_MODE is ignored and Wine uses $HOME/.wine
out=$(run_cmd -e PREFIX_MODE=bogus "$IMAGE" bash -c 'echo "$WINEPREFIX"' 2>/dev/null)
[ "$out" = /home/wineuser/.wine ] || fail "plain image WINEPREFIX is '$out'"
pass
```

`tests/cases/prefix-recovery.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
img=$(fixture_image 1)

# A leftover partial copy is discarded and seeding completes
vol=$(new_volume partial)
"$RUNTIME" run --rm --user 123456:0 --entrypoint bash -v "$vol:/home/wineuser" "$img" \
    -c 'mkdir -p ~/.wine.partial && echo 1 > ~/.wine.partial/.prefix-version'
out=$(run_home "$vol" "$img" bash -c 'cat ~/.wine/.prefix-version; test ! -e ~/.wine.partial && echo clean' 2>/dev/null)
[ "$out" = $'1\nclean' ] || fail "partial copy not recovered: $out"

# A prefix owned by another uid (pre-migration winehome) fails with migration instructions
vol2=$(new_volume foreign)
"$RUNTIME" run --rm --user 0 --entrypoint bash -v "$vol2:/home/wineuser" "$img" \
    -c 'mkdir -p /home/wineuser/.wine && echo 1 > /home/wineuser/.wine/.prefix-version && chown -R 1010:1010 /home/wineuser/.wine'
out=$(run_home "$vol2" "$img" true 2>&1) && fail "started with a foreign-owned prefix"
grep -q "/home/wineuser/.wine is owned by uid 1010" <<<"$out" || fail "unexpected output: $out"
grep -q "chown -R" <<<"$out" || fail "no migration hint: $out"
pass
```

`tests/cases/finalize-requires-version.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
log=$(mktemp)
trap 'cleanup; rm -f "$log"' EXIT
if "$RUNTIME" build --progress=plain --build-arg "BASE_IMAGE=$IMAGE" --build-arg PREFIX_VERSION= \
    "$REPO_ROOT/tests/fixtures/derived" >"$log" 2>&1; then
    fail "finalize succeeded without PREFIX_VERSION"
fi
grep -q "PREFIX_VERSION must be set" "$log" || fail "unclear finalize error: $(tail -n5 "$log")"
pass
```

`tests/cases/desktop-smoke.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
name=$(start_desktop smoke)
wait_healthy "$name" 180
"$RUNTIME" logs "$name" 2>&1 | grep -q "using Wine prefix /home/wineuser/.wine (PREFIX_MODE=seed)" \
    || fail "hook did not report the prefix"
pass
```

- [ ] **Step 2: Run them to verify they fail**

```bash
BASE_IMAGE=docker-remote-desktop:local ./build -q && tests/run docker-wine:local tests/cases/prefix-seed.sh tests/cases/desktop-smoke.sh
```

Expected: FAIL. The fixture build fails with `wine-prefix: command not found`, and the smoke test finds no `using Wine prefix` line.

- [ ] **Step 3: Implement `wine-prefix`**

`rootfs/usr/local/bin/wine-prefix`:

```bash
#!/usr/bin/env bash
# Manage the Wine prefix of docker-wine based images.
#   wine-prefix run -- CMD [ARGS...]   (build time) run CMD against the template prefix under Xvfb
#   wine-prefix finalize               (build time) clean the template and stamp $PREFIX_VERSION
#   wine-prefix init                   (runtime)    prepare the runtime prefix, print its path
set -Eeuo pipefail

TEMPLATE=/opt/wine/prefix-template
EPHEMERAL_DIR=/run/wine-prefix
SHELL_FOLDERS=(Documents Desktop Downloads)

log() { printf 'wine-prefix: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

cmd_run() {
    [ "${1:-}" != -- ] || shift
    [ $# -gt 0 ] || die "usage: wine-prefix run -- COMMAND [ARGS...]"
    export WINEPREFIX="$TEMPLATE"
    if [ ! -f "$TEMPLATE/system.reg" ]; then
        log "initialising template prefix $TEMPLATE"
        xvfb-run -a wineboot -i
        wineserver -w
    fi
    xvfb-run -a "$@"
    wineserver -w
}

cmd_finalize() {
    [ -n "${PREFIX_VERSION:-}" ] || die "PREFIX_VERSION must be set (for example ENV PREFIX_VERSION=myapp-1.2.3-1)"
    [ -f "$TEMPLATE/system.reg" ] || die "no template prefix at $TEMPLATE; run 'wine-prefix run -- ...' first"
    WINEPREFIX="$TEMPLATE" wineserver -k 2>/dev/null || true
    rm -rf "$TEMPLATE"/drive_c/windows/temp/* "$TEMPLATE"/drive_c/users/*/Temp/* \
        "$TEMPLATE"/drive_c/users/*/AppData/Local/Temp/* "$HOME/.cache/winetricks"
    local users_dir folder
    users_dir="$TEMPLATE/drive_c/users/$(id -un)"
    mkdir -p "$users_dir"
    for folder in "${SHELL_FOLDERS[@]}"; do
        rm -rf "${users_dir:?}/$folder"
        ln -s "/home/wineuser/$folder" "$users_dir/$folder"
    done
    printf '%s\n' "$PREFIX_VERSION" > "$TEMPLATE/.prefix-version"
    chmod -R g=u "$TEMPLATE"
    log "template prefix finalized as version $PREFIX_VERSION"
}

copy_template() {
    local dest=$1 start=$SECONDS
    cp -a --no-preserve=ownership "$TEMPLATE/." "$dest/"
    log "copied template prefix to $dest in $((SECONDS - start))s"
}

init_seed() {
    local target="$HOME/.wine" image_version=$1 current owner
    rm -rf "$target.partial"
    if [ ! -e "$target" ]; then
        mkdir "$target.partial"
        copy_template "$target.partial"
        mv "$target.partial" "$target"
        return 0
    fi
    owner=$(stat -c %u "$target")
    if [ "$owner" != "$(id -u)" ]; then
        die "$target is owned by uid $owner, but the container runs as uid $(id -u). Migrate the volume once:" \
            "docker run --rm --user 0 --entrypoint chown -v VOLUME:/home/wineuser IMAGE -R $(id -u):0 /home/wineuser"
    fi
    current=$(cat "$target/.prefix-version" 2>/dev/null || echo unknown)
    [ "$current" != "$image_version" ] || return 0
    case "${PREFIX_UPGRADE:-fail}" in
        fail)
            die "prefix version $current does not match image version $image_version; set PREFIX_UPGRADE=reseed or keep" ;;
        keep)
            log "WARNING: keeping prefix version $current although the image provides $image_version" ;;
        reseed)
            rm -rf "$target.bak-$current"
            mkdir "$target.partial"
            copy_template "$target.partial"
            mv "$target" "$target.bak-$current"
            mv "$target.partial" "$target"
            log "reseeded prefix; previous prefix kept as $target.bak-$current" ;;
    esac
}

init_ephemeral() {
    [ -d "$EPHEMERAL_DIR" ] && [ -w "$EPHEMERAL_DIR" ] \
        || die "$EPHEMERAL_DIR is not writable; mount an emptyDir (OpenShift) or a volume (docker -v $EPHEMERAL_DIR) there"
    find "$EPHEMERAL_DIR" -mindepth 1 -delete
    copy_template "$EPHEMERAL_DIR"
}

cmd_init() {
    case "${PREFIX_UPGRADE:-fail}" in
        fail | reseed | keep) ;;
        *) die "invalid PREFIX_UPGRADE '${PREFIX_UPGRADE}'; valid values: fail, reseed, keep" ;;
    esac
    if [ ! -f "$TEMPLATE/.prefix-version" ]; then
        printf '%s\n' "$HOME/.wine"
        return 0
    fi
    local image_version folder
    image_version=$(<"$TEMPLATE/.prefix-version")
    for folder in "${SHELL_FOLDERS[@]}"; do mkdir -p "$HOME/$folder"; done
    case "${PREFIX_MODE:-seed}" in
        seed)
            init_seed "$image_version"
            printf '%s\n' "$HOME/.wine" ;;
        ephemeral)
            init_ephemeral
            printf '%s\n' "$EPHEMERAL_DIR" ;;
        *)
            die "invalid PREFIX_MODE '${PREFIX_MODE}'; valid values: seed, ephemeral" ;;
    esac
}

case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    finalize) cmd_finalize ;;
    init) cmd_init ;;
    *) die "usage: wine-prefix run -- COMMAND... | finalize | init" ;;
esac
```

- [ ] **Step 4: Implement the hook and update the Dockerfile**

`rootfs/etc/desktop/init.d/50-wine-prefix.sh`:

```bash
# shellcheck shell=bash
# Sourced by /usr/local/bin/desktop: selects and prepares the Wine prefix (see wine-prefix init).
WINEPREFIX="$(wine-prefix init)" || die "Wine prefix initialisation failed (see messages above)"
export WINEPREFIX
log "using Wine prefix $WINEPREFIX (PREFIX_MODE=${PREFIX_MODE:-seed})"
```

In `Dockerfile`, replace `RUN chmod 0755 /usr/local/bin/fetch-verified \` with:

```dockerfile
RUN chmod 0755 /usr/local/bin/fetch-verified /usr/local/bin/wine-prefix \
 && chmod 0644 /etc/desktop/init.d/50-wine-prefix.sh \
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
BASE_IMAGE=docker-remote-desktop:local ./build -q && tests/run docker-wine:local
```

Expected: all 13 cases PASS.

- [ ] **Step 6: Commit**

```bash
git add -A Dockerfile rootfs tests
git commit -m "feat: wine-prefix tool with seed and ephemeral prefix modes" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `run-local`

**Files:**
- Create: `run-local`, `tests/cases/run-local.sh`

**Interfaces:**
- Produces: `run-local IMAGE [--name NAME] [--home-volume VOLUME] [--port PORT] [--ephemeral]`. Defaults: `--name docker-wine`, `--home-volume winehome`, `--port 3389`.

- [ ] **Step 1: Write the failing test**

`tests/cases/run-local.sh`:

```bash
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
"$RUNTIME" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" | grep -qx PREFIX_MODE=ephemeral \
    || fail "--ephemeral not applied"
wait_healthy "$name" 180

out=$("$REPO_ROOT/run-local" does-not-exist.invalid/image:never 2>&1) && fail "accepted a missing image"
grep -q "not found locally" <<<"$out" || fail "unexpected output: $out"

out=$("$REPO_ROOT/run-local" "$IMAGE" --port 99999 2>&1) && fail "accepted port 99999"
grep -q "invalid port" <<<"$out" || fail "unexpected output: $out"
pass
```

- [ ] **Step 2: Run it to verify it fails**

```bash
tests/run docker-wine:local tests/cases/run-local.sh
```

Expected: FAIL with `run-local: No such file or directory`.

- [ ] **Step 3: Implement `run-local`**

```bash
#!/usr/bin/env bash
# Run a docker-wine based image locally in RDP mode with hardened defaults.
# The RDP port is published on 127.0.0.1 only; anyone who can reach it gets the desktop (no password).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: run-local IMAGE [--name NAME] [--home-volume VOLUME] [--port PORT] [--ephemeral]

  IMAGE                 image reference, must already be present locally (never pulled implicitly)
  --name NAME           container name (default: docker-wine)
  --home-volume VOLUME  volume for /home/wineuser (default: winehome)
  --port PORT           local port on 127.0.0.1 (default: 3389)
  --ephemeral           PREFIX_MODE=ephemeral with an anonymous volume at /run/wine-prefix
EOF
}

die() { echo "run-local: $*" >&2; exit 2; }

[ $# -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
esac
image=$1
shift
name=docker-wine
home_volume=winehome
port=3389
ephemeral=no
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name=${2:?--name requires a value}; shift 2 ;;
        --name=*) name=${1#*=}; shift ;;
        --home-volume) home_volume=${2:?--home-volume requires a value}; shift 2 ;;
        --home-volume=*) home_volume=${1#*=}; shift ;;
        --port) port=${2:?--port requires a value}; shift 2 ;;
        --port=*) port=${1#*=}; shift ;;
        --ephemeral) ephemeral=yes; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option $1" ;;
    esac
done
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "invalid port '$port'"

if command -v docker >/dev/null 2>&1; then
    rt=docker
elif command -v podman >/dev/null 2>&1; then
    rt=podman
else
    die "neither docker nor podman found"
fi
"$rt" image inspect "$image" >/dev/null 2>&1 || die "image $image not found locally; pull it first: $rt pull $image"

args=(run -d --name "$name" --pull never
    --user 1001:0 --cap-drop ALL --security-opt no-new-privileges --read-only
    --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --shm-size 1g
    -v "$home_volume:/home/wineuser" -e RDP_LISTEN_ADDRESS=0.0.0.0
    -p "127.0.0.1:$port:3389")
[ "$ephemeral" = no ] || args+=(-e PREFIX_MODE=ephemeral -v /run/wine-prefix)

"$rt" "${args[@]}" "$image"
echo "Connect an RDP client to 127.0.0.1:$port (self-signed certificate; no password)"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
tests/run docker-wine:local tests/cases/run-local.sh
```

Expected: `PASS [run-local]`.

- [ ] **Step 5: Commit**

```bash
git add run-local tests/cases/run-local.sh
git commit -m "feat: run-local with hardened defaults and no implicit pulls" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Update scripts, Renovate preset and the fixup workflow

**Files:**
- Create: `scripts/update-downloads`, `scripts/update-addons`, `renovate/preset.json`, `renovate.json`, `.github/workflows/renovate-fixup.yml`, `tests/cases/update-downloads.sh`

**Interfaces:**
- Consumes: `upstream_wine_version` (Task 1) and the lock format (Task 2).
- Produces:
  - `scripts/update-downloads [LOCKFILE...]`: defaults to `addons.lock` plus `examples/*/downloads.lock`.
  - `scripts/update-addons [WINE_PACKAGE_VERSION]`.
  - The preset `github>kamphaus/docker-wine//renovate/preset`.

- [ ] **Step 1: Write the failing test**

`tests/cases/update-downloads.sh`. It runs on the host and needs `curl` and network access.

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir=$(mktemp -d)
trap 'cleanup; rm -rf "$dir"' EXIT
mkdir -p "$dir/scripts"
cp "$REPO_ROOT/scripts/update-downloads" "$dir/scripts/"
cat > "$dir/test.lock" <<'EOF'
# keep this comment
winetricks b76e1ee79ac57d7aceb384f74518fc423265810c https://raw.githubusercontent.com/Winetricks/winetricks/{version}/src/winetricks sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
"$dir/scripts/update-downloads" "$dir/test.lock" >/dev/null
grep -qx '# keep this comment' "$dir/test.lock" || fail "comment lost"
grep -q 'sha256:431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b$' "$dir/test.lock" \
    || fail "checksum not updated: $(cat "$dir/test.lock")"
grep -q '/{version}/src/winetricks' "$dir/test.lock" || fail "URL template was expanded in the lock file"
pass
```

- [ ] **Step 2: Run it to verify it fails**

```bash
tests/run docker-wine:local tests/cases/update-downloads.sh
```

Expected: FAIL. `scripts/update-downloads` doesn't exist yet.

- [ ] **Step 3: Implement the scripts**

`scripts/update-downloads`:

```bash
#!/usr/bin/env bash
# Recompute the sha256 of every entry in downloads.lock-format files (format: see fetch-verified).
# Usage: scripts/update-downloads [LOCKFILE...]   (default: addons.lock and examples/*/downloads.lock)
set -euo pipefail
cd "$(dirname "$0")/.."

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    files=(addons.lock)
    for f in examples/*/downloads.lock; do
        [ -e "$f" ] && files+=("$f")
    done
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for lock in "${files[@]}"; do
    : > "$tmp/out"
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
            printf '%s\n' "$line" >> "$tmp/out"
            continue
        fi
        read -r name version url _ <<<"$line"
        curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$tmp/download" "${url//\{version\}/$version}"
        sum=$(sha256sum "$tmp/download" | cut -d' ' -f1)
        printf '%s %s %s sha256:%s\n' "$name" "$version" "$url" "$sum" >> "$tmp/out"
    done < "$lock"
    if ! cmp -s "$tmp/out" "$lock"; then
        cat "$tmp/out" > "$lock"
        echo "updated $lock"
    fi
done
```

`scripts/update-addons`:

```bash
#!/usr/bin/env bash
# Regenerate addons.lock with the Gecko/Mono versions that the pinned Wine release expects.
# Usage: scripts/update-addons [WINE_PACKAGE_VERSION]   (default: ARG WINE_VERSION in Dockerfile)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/wine-version.sh

pkg=${1:-$(sed -n 's/^ARG WINE_VERSION=//p' Dockerfile)}
[ -n "$pkg" ] || { echo "update-addons: no ARG WINE_VERSION in Dockerfile" >&2; exit 1; }
upstream=$(upstream_wine_version "$pkg")
addons_c=$(curl -fsSL "https://raw.githubusercontent.com/wine-mirror/wine/wine-${upstream}/dlls/appwiz.cpl/addons.c")
gecko=$(sed -n -E 's/^#define GECKO_VERSION "([^"]+)".*/\1/p' <<<"$addons_c")
mono=$(sed -n -E 's/^#define MONO_VERSION "([^"]+)".*/\1/p' <<<"$addons_c")
if [ -z "$gecko" ] || [ -z "$mono" ]; then
    echo "update-addons: could not read add-on versions for wine-${upstream}" >&2
    exit 1
fi

base=https://dl.winehq.org/wine
cat > addons.lock <<EOF
# Wine add-ons required by wine-${upstream}. Regenerate with: scripts/update-addons
wine-gecko-{version}-x86.msi ${gecko} ${base}/wine-gecko/{version}/wine-gecko-{version}-x86.msi sha256:pending
wine-gecko-{version}-x86_64.msi ${gecko} ${base}/wine-gecko/{version}/wine-gecko-{version}-x86_64.msi sha256:pending
wine-mono-{version}-x86.msi ${mono} ${base}/wine-mono/{version}/wine-mono-{version}-x86.msi sha256:pending
EOF
scripts/update-downloads addons.lock
```

- [ ] **Step 4: Run the test, then check that `update-addons` reproduces the committed lock**

```bash
chmod +x scripts/update-downloads scripts/update-addons
git update-index --chmod=+x scripts/update-downloads scripts/update-addons run-local build tests/run rootfs/usr/local/bin/*
tests/run docker-wine:local tests/cases/update-downloads.sh
scripts/update-addons && git diff --exit-code addons.lock
```

Expected: `PASS [update-downloads]`, then `updated addons.lock` followed by an empty diff. The regenerated file is byte-identical to the committed one.

- [ ] **Step 5: Write the Renovate preset and the repo config**

`renovate/preset.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "description": "Shared Renovate preset for docker-wine and images derived from it",
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
    },
    {
      "customType": "regex",
      "description": "downloads.lock entries annotated with '# renovate:'",
      "managerFilePatterns": ["/(^|/)[^/]+\\.lock$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)(?: extractVersion=(?<extractVersion>\\S+))?\\s+\\S+ (?<currentValue>\\S+) "
      ],
      "extractVersionTemplate": "{{#if extractVersion}}{{{extractVersion}}}{{else}}^(?<version>.+)${{/if}}"
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
    },
    {
      "description": "Wine bumps change add-ons and behaviour: always review",
      "matchDepNames": ["winehq-stable"],
      "automerge": false
    }
  ]
}
```

`renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>kamphaus/docker-wine//renovate/preset"]
}
```

Validate both:

```bash
for f in renovate/preset.json renovate.json; do
  docker run --rm -v "$PWD/$f:/config.json:ro" --entrypoint renovate-config-validator renovate/renovate:latest /config.json
done
```

Expected: `Config validated successfully` twice. The unpinned validator image is a local, throwaway check only.

- [ ] **Step 6: Write `.github/workflows/renovate-fixup.yml`**

```yaml
name: renovate-fixup

on:
  pull_request:
    paths:
      - Dockerfile
      - '**/*.lock'
      - 'examples/**/Dockerfile'

permissions:
  contents: read

jobs:
  fixup:
    if: startsWith(github.head_ref, 'renovate/') && github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      actions: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.head_ref }}
      - name: Recompute add-on versions and checksums
        run: |
          scripts/update-addons
          scripts/update-downloads
      - name: Commit and re-run CI
        env:
          GH_TOKEN: ${{ github.token }}
          BRANCH: ${{ github.head_ref }}
        run: |
          if git diff --quiet; then
            echo "add-ons and checksums already up to date"
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "build(deps): update add-on versions and download checksums"
          git push origin "HEAD:$BRANCH"
          # Commits pushed with GITHUB_TOKEN do not trigger pull_request workflows: dispatch CI explicitly.
          gh workflow run ci.yml --ref "$BRANCH"
```

- [ ] **Step 7: Lint and commit**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
git add -A scripts renovate renovate.json .github/workflows/renovate-fixup.yml tests/cases/update-downloads.sh
git commit -m "build: Renovate preset, add-on regeneration and checksum fixup workflow" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: actionlint prints nothing.

---

### Task 6: CI pipeline

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - The `image` artifact (gzipped `docker save` of `docker-wine:ci`), uploaded on every run. Task 7's `kind` job consumes it.
  - On `master`: `ghcr.io/kamphaus/docker-wine:<upstream>-<sha7>` and `:stable`, signed and attested.

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
  IMAGE_NAME: ghcr.io/kamphaus/docker-wine
  TRIVY_IMAGE: aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa

jobs:
  build-test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
        with:
          driver: docker
      - name: Build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          load: true
          tags: docker-wine:ci
      - name: Test
        run: tests/run docker-wine:ci
      - name: Scan
        run: >-
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE"
          image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 docker-wine:ci
      - name: Save tested image
        run: docker save docker-wine:ci | gzip > image.tar.gz
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: image
      - name: Load and tag
        id: tag
        run: |
          source scripts/lib/wine-version.sh
          gunzip -c image.tar.gz | docker load
          upstream=$(upstream_wine_version "$(sed -n 's/^ARG WINE_VERSION=//p' Dockerfile)")
          version="${upstream}-${GITHUB_SHA::7}"
          docker tag docker-wine:ci "$IMAGE_NAME:$version"
          docker tag docker-wine:ci "$IMAGE_NAME:stable"
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
          docker push "$IMAGE_NAME:stable"
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

- [ ] **Step 2: Lint and commit**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
git add .github/workflows/ci.yml
git commit -m "ci: build once, test, scan, then push, attest and sign the tested image" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: actionlint prints nothing.

---

### Task 7: OpenShift deployment, `oc-rdp`, static validation and the kind end-to-end test

**Files:**
- Create:
  - `deploy/openshift/base/{kustomization.yaml,deployment.yaml,pvc.yaml,networkpolicy.yaml,role.yaml}`
  - `deploy/openshift/components/egress-deny/{kustomization.yaml,networkpolicy.yaml}`
  - `deploy/openshift/overlays/example-user/{kustomization.yaml,rolebinding.yaml}`
  - `scripts/oc-rdp`
  - `tests/manifests/validate`
  - `tests/k8s/overlay/{kustomization.yaml,namespace.yaml}`
  - `tests/k8s/kind-e2e.sh`
  - `tests/rdp-client/Dockerfile`
- Modify: `.github/workflows/ci.yml` (add the `manifests` and `kind` jobs)

**Interfaces:**
- Consumes: the `image` artifact (Task 6) and the `desktop healthcheck` probe.
- Produces:
  - A Deployment named `wine-desktop` (label `app.kubernetes.io/name: wine-desktop`) and a PVC named `wine-desktop-home`.
  - A Role named `desktop-user`.
  - `scripts/oc-rdp [-n NAMESPACE] [-c xfreerdp|mstsc] [DEPLOYMENT] [LOCAL_PORT]`.

- [ ] **Step 1: Write the failing validation test**

`tests/manifests/validate`:

```bash
#!/usr/bin/env bash
# Render every kustomization and validate it; assert the security-relevant fields of the base.
set -euo pipefail
cd "$(dirname "$0")/../.."
KUBECONFORM=ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e

fail() { echo "FAIL [manifests]: $*" >&2; exit 1; }

for dir in deploy/openshift/base deploy/openshift/overlays/example-user tests/k8s/overlay; do
    kubectl kustomize "$dir" | docker run --rm -i "$KUBECONFORM" -strict -summary - || fail "$dir does not validate"
done

base=$(kubectl kustomize deploy/openshift/base)
! grep -q '^kind: Service$' <<<"$base" || fail "base must not contain a Service"
! grep -q '^kind: Route$' <<<"$base" || fail "base must not contain a Route"
for want in 'automountServiceAccountToken: false' 'enableServiceLinks: false' 'allowPrivilegeEscalation: false' \
    'runAsNonRoot: true' 'type: RuntimeDefault' 'readOnlyRootFilesystem: true' '- ALL' 'type: Recreate' \
    'value: 127.0.0.1' 'medium: Memory'; do
    grep -qF -- "$want" <<<"$base" || fail "base is missing '$want'"
done
! grep -q 'runAsUser:' <<<"$base" || fail "base must let the SCC assign runAsUser"
grep -q 'resources:$' <<<"$(kubectl kustomize deploy/openshift/overlays/example-user)" || fail "overlay lost resources"
echo "PASS [manifests]"
```

Run it:

```bash
chmod +x tests/manifests/validate && tests/manifests/validate
```

Expected: FAIL, because `deploy/openshift/base` doesn't exist yet.

- [ ] **Step 2: Write the base manifests**

`deploy/openshift/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/name: wine-desktop
    includeSelectors: false
resources:
  - deployment.yaml
  - pvc.yaml
  - networkpolicy.yaml
  - role.yaml
images:
  - name: ghcr.io/kamphaus/docker-wine
    newTag: stable
```

`deploy/openshift/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wine-desktop
spec:
  replicas: 1
  strategy:
    type: Recreate   # the RWO home PVC cannot be attached to two pods during a rolling update
  selector:
    matchLabels:
      app.kubernetes.io/name: wine-desktop
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wine-desktop
    spec:
      automountServiceAccountToken: false   # untrusted Windows binaries must not get a cluster credential
      enableServiceLinks: false
      nodeSelector:
        kubernetes.io/arch: amd64
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: desktop
          image: ghcr.io/kamphaus/docker-wine
          env:
            - name: RDP_LISTEN_ADDRESS
              value: 127.0.0.1   # reachable only through `oc port-forward`
            - name: PREFIX_MODE
              value: seed
            - name: PREFIX_UPGRADE
              value: fail
            - name: TZ
              value: UTC
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
          startupProbe:   # seeding a large prefix can take minutes
            exec:
              command: [/usr/local/bin/desktop, healthcheck]
            periodSeconds: 5
            failureThreshold: 120
          livenessProbe:
            exec:
              command: [/usr/local/bin/desktop, healthcheck]
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: home
              mountPath: /home/wineuser
            - name: shm
              mountPath: /dev/shm
            - name: tmp
              mountPath: /tmp
            - name: runtime
              mountPath: /run/desktop
            - name: wine-prefix
              mountPath: /run/wine-prefix
            - name: tls
              mountPath: /etc/desktop/tls
              readOnly: true
      volumes:
        - name: home
          persistentVolumeClaim:
            claimName: wine-desktop-home
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
        - name: tmp
          emptyDir: {}
        - name: runtime
          emptyDir: {}
        - name: wine-prefix
          emptyDir: {}
        - name: tls
          secret:
            secretName: wine-desktop-tls   # optional kubernetes.io/tls Secret, e.g. from cert-manager
            optional: true
```

`deploy/openshift/base/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wine-desktop-home
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
```

`deploy/openshift/base/networkpolicy.yaml`:

```yaml
# Deny all ingress: `oc port-forward` reaches the pod's loopback through the kubelet and is unaffected.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wine-desktop-deny-ingress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: wine-desktop
  policyTypes:
    - Ingress
```

`deploy/openshift/base/role.yaml`:

```yaml
# Holders of this Role (or of the built-in edit/admin roles) can open the desktop: it has no password.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: desktop-user
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [get, create]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [get]
```

- [ ] **Step 3: Write the egress component and the example overlay**

`deploy/openshift/components/egress-deny/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - networkpolicy.yaml
```

`deploy/openshift/components/egress-deny/networkpolicy.yaml`:

```yaml
# Deny all egress except cluster DNS. Add allow rules for license servers etc., for example:
#   - to: [{ipBlock: {cidr: 10.20.30.40/32}}]
#     ports: [{protocol: TCP, port: 27000}]
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wine-desktop-egress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: wine-desktop
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-dns
      ports:
        - protocol: UDP
          port: 5353
        - protocol: TCP
          port: 5353
```

`deploy/openshift/overlays/example-user/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namePrefix: alice-
resources:
  - ../../base
  - rolebinding.yaml
components:
  - ../../components/egress-deny
patches:
  - target:
      kind: PersistentVolumeClaim
      name: wine-desktop-home
    patch: |-
      - op: replace
        path: /spec/resources/requests/storage
        value: 50Gi
  - target:
      kind: Deployment
      name: wine-desktop
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/1/value
        value: ephemeral
```

`deploy/openshift/overlays/example-user/rolebinding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: desktop-user
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: alice
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: desktop-user
```

- [ ] **Step 4: Write the kind overlay, the RDP client and `oc-rdp`**

`tests/k8s/overlay/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: desktop-e2e
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

`tests/k8s/overlay/kustomization.yaml`:

```yaml
# Approximates OpenShift restricted-v2 on kind: Pod Security "restricted", a high arbitrary UID, GID 0.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: desktop-e2e
resources:
  - namespace.yaml
  - ../../../deploy/openshift/base
images:
  - name: ghcr.io/kamphaus/docker-wine
    newName: docker-wine
    newTag: kind-e2e
patches:
  - target:
      kind: Deployment
      name: wine-desktop
    patch: |-
      - op: add
        path: /spec/template/spec/securityContext/runAsUser
        value: 1000700000
      - op: add
        path: /spec/template/spec/securityContext/fsGroup
        value: 1000700000
      - op: add
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: Never
      - op: replace
        path: /spec/template/spec/containers/0/resources
        value:
          requests: {cpu: 500m, memory: 1Gi}
          limits: {cpu: "2", memory: 4Gi}
```

`tests/rdp-client/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# RDP client for tests/k8s/kind-e2e.sh (FreeRDP under Xvfb), reusing the base image's pinned apt snapshot.
FROM ghcr.io/kamphaus/docker-remote-desktop:noble@sha256:<same digest as Dockerfile BASE_IMAGE>
USER 0
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends freerdp2-x11 xauth xvfb \
 && rm -rf /var/lib/apt/lists/*
USER 1001
ENTRYPOINT []
```

Fill in the digest with the same value as `ARG BASE_IMAGE` in `Dockerfile`:

```bash
sed -n 's/^ARG BASE_IMAGE=.*@//p' Dockerfile
```

`scripts/oc-rdp`:

```bash
#!/usr/bin/env bash
# Tunnel RDP to a wine-desktop deployment through `oc port-forward` and keep the tunnel up.
# Usage: scripts/oc-rdp [-n NAMESPACE] [-c xfreerdp|mstsc] [DEPLOYMENT] [LOCAL_PORT]
#   defaults: DEPLOYMENT=wine-desktop LOCAL_PORT=13389; -c launches that RDP client once the tunnel is up
set -euo pipefail

usage() { sed -n '2,4s/^# \{0,1\}//p' "$0"; }

namespace=()
client=""
while getopts "n:c:h" opt; do
    case $opt in
        n) namespace=(-n "$OPTARG") ;;
        c) client=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
deployment=${1:-wine-desktop}
port=${2:-13389}
case "$client" in
    "" | xfreerdp | mstsc) ;;
    *) echo "oc-rdp: unknown client '$client' (use xfreerdp or mstsc)" >&2; exit 2 ;;
esac

cli=$(command -v oc || command -v kubectl) || { echo "oc-rdp: neither oc nor kubectl found" >&2; exit 1; }
"$cli" "${namespace[@]}" get deployment "$deployment" >/dev/null

launch_client() {
    case "$client" in
        "") echo "oc-rdp: connect an RDP client to localhost:$port (expect a self-signed certificate warning)" ;;
        xfreerdp) xfreerdp /v:"localhost:$port" /cert:tofu /dynamic-resolution /sound +clipboard & ;;
        mstsc) mstsc.exe /v:"localhost:$port" & ;;
    esac
}

pf=""
trap '[ -z "$pf" ] || kill "$pf" 2>/dev/null' EXIT
first=yes
while true; do
    "$cli" "${namespace[@]}" port-forward "deployment/$deployment" "$port:3389" &
    pf=$!
    if [ "$first" = yes ]; then
        for _ in $(seq 30); do
            (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
            sleep 1
        done
        launch_client
        first=no
    fi
    wait "$pf" || true
    echo "oc-rdp: port-forward ended; reconnecting in 2s (Ctrl-C to quit)" >&2
    sleep 2
done
```

- [ ] **Step 5: Run the static validation**

```bash
chmod +x scripts/oc-rdp && git update-index --chmod=+x scripts/oc-rdp tests/manifests/validate
tests/manifests/validate
```

Expected: three kubeconform summaries with `Invalid: 0, Errors: 0`, then `PASS [manifests]`.

- [ ] **Step 6: Write the kind end-to-end test**

`tests/k8s/kind-e2e.sh`:

```bash
#!/usr/bin/env bash
# Deploy IMAGE to the current kind cluster under Pod Security "restricted" and connect through oc-rdp.
# Usage: tests/k8s/kind-e2e.sh IMAGE      (requires kind, kubectl, docker and an existing kind cluster)
set -euo pipefail
image=${1:?usage: tests/k8s/kind-e2e.sh IMAGE}
cd "$(dirname "$0")/../.."
cluster=${KIND_CLUSTER:-kind}
ns=desktop-e2e

docker tag "$image" docker-wine:kind-e2e
kind load docker-image docker-wine:kind-e2e --name "$cluster"
docker build -q -t desktop-test-rdp-client tests/rdp-client >/dev/null

tunnel=""
finish() {
    [ -z "$tunnel" ] || kill "$tunnel" 2>/dev/null || true
    docker rm -f kind-e2e-client >/dev/null 2>&1 || true
}
trap finish EXIT

kubectl apply -k tests/k8s/overlay
if ! kubectl -n "$ns" rollout status deployment/wine-desktop --timeout=600s; then
    kubectl -n "$ns" describe pods
    kubectl -n "$ns" logs deployment/wine-desktop --tail=100 || true
    echo "FAIL [kind-e2e]: deployment did not become ready" >&2
    exit 1
fi

scripts/oc-rdp -n "$ns" wine-desktop 13389 >/dev/null 2>&1 &
tunnel=$!
docker run -d --name kind-e2e-client --network host desktop-test-rdp-client \
    xvfb-run -a xfreerdp /v:127.0.0.1:13389 /cert:ignore /sec:tls /u:wineuser /p:unused /sound:sys:fake +clipboard >/dev/null

for _ in $(seq 60); do
    if kubectl -n "$ns" exec deployment/wine-desktop -- grep -q 'connected to X11rdp_pid' /run/desktop/log/xrdp.log 2>/dev/null; then
        echo "PASS [kind-e2e]"
        exit 0
    fi
    sleep 2
done
kubectl -n "$ns" logs deployment/wine-desktop --tail=100 || true
echo "FAIL [kind-e2e]: no RDP session through the port-forward tunnel" >&2
exit 1
```

Run it locally if `kind` is available (CI runs it in Step 7):

```bash
chmod +x tests/k8s/kind-e2e.sh && git update-index --chmod=+x tests/k8s/kind-e2e.sh
kind create cluster && tests/k8s/kind-e2e.sh docker-wine:local; kind delete cluster
```

Expected: `PASS [kind-e2e]`.

- [ ] **Step 7: Add the `manifests` and `kind` jobs to `ci.yml`**

Append under `jobs:`:

```yaml
  manifests:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Validate manifests
        run: tests/manifests/validate

  kind:
    needs: build-test
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: image
      - name: Load image
        run: gunzip -c image.tar.gz | docker load
      - uses: helm/kind-action@1544676c07bb3570fcb70166beaa07c4528fd4aa # v1.15.1
        with:
          version: v0.33.0
          cluster_name: kind
      - name: End-to-end on kind (Pod Security restricted)
        run: tests/k8s/kind-e2e.sh docker-wine:ci
```

- [ ] **Step 8: Lint and commit**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
git add -A deploy scripts/oc-rdp tests/manifests tests/k8s tests/rdp-client .github/workflows/ci.yml
git commit -m "feat: OpenShift Kustomize deployment, oc-rdp and kind end-to-end test" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: actionlint prints nothing.

---

### Task 8: Derived images: reusable workflow and the Notepad++ example

**Files:**
- Create: `.github/workflows/build-derived.yml`, `examples/notepadpp/Dockerfile`, `examples/notepadpp/downloads.lock`, `examples/notepadpp/notepadpp`, `examples/notepadpp/notepadpp.desktop`
- Modify: `.github/workflows/ci.yml` (add the `example` job)

**Interfaces:**
- Consumes: `fetch-verified`, `wine-prefix run`, `wine-prefix finalize` and `PREFIX_VERSION`.
- Produces: the reusable workflow `kamphaus/docker-wine/.github/workflows/build-derived.yml@<sha>` with inputs `context` (string, default `.`), `image-name` (string, required), `test-command` (string, default `true`) and `push` (boolean, default `false`).

- [ ] **Step 1: Write the example**

`examples/notepadpp/downloads.lock`:

```
# renovate: datasource=github-releases depName=notepad-plus-plus/notepad-plus-plus extractVersion=^v(?<version>.+)$
npp-installer.exe 8.9.8.1 https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v{version}/npp.{version}.Installer.x64.exe sha256:26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da
```

`examples/notepadpp/notepadpp`:

```bash
#!/usr/bin/env bash
# Launch Notepad++ from whichever prefix the wine-prefix hook selected.
exec wine "$WINEPREFIX/drive_c/Program Files/Notepad++/notepad++.exe" "$@"
```

`examples/notepadpp/notepadpp.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Notepad++
Exec=/usr/local/bin/notepadpp
X-GNOME-Autostart-enabled=true
```

`examples/notepadpp/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# Example derived image: Notepad++ pre-installed in the template prefix.
# Bump PREFIX_VERSION whenever the installed software changes (for example when downloads.lock is updated);
# existing seed-mode prefixes then require PREFIX_UPGRADE=reseed or keep.
ARG BASE_IMAGE=ghcr.io/kamphaus/docker-wine:stable
FROM ${BASE_IMAGE}
ENV PREFIX_VERSION=notepadpp-8.9.8.1-1
RUN --mount=type=bind,source=downloads.lock,target=/tmp/downloads.lock \
    fetch-verified /tmp/downloads.lock /tmp/dl \
 && wine-prefix run -- wine /tmp/dl/npp-installer.exe /S \
 && wine-prefix finalize \
 && rm -rf /tmp/dl
COPY --chmod=0755 notepadpp /usr/local/bin/notepadpp
COPY --chmod=0644 notepadpp.desktop /etc/xdg/autostart/notepadpp.desktop
```

- [ ] **Step 2: Build and smoke-test the example locally**

```bash
docker build -t notepadpp:dev --build-arg BASE_IMAGE=docker-wine:local examples/notepadpp
docker run --rm --user 123456:0 --tmpfs /home/wineuser:mode=0770 notepadpp:dev \
  bash -c 'test -f "$WINEPREFIX/drive_c/Program Files/Notepad++/notepad++.exe" && echo installed'
```

Expected: the build succeeds and `installed` is printed.

- [ ] **Step 3: Write the reusable workflow**

`.github/workflows/build-derived.yml`:

```yaml
name: build-derived

on:
  workflow_call:
    inputs:
      context:
        description: Build context containing the Dockerfile
        type: string
        default: .
      image-name:
        description: Target image, e.g. ghcr.io/kamphaus/notepadpp
        type: string
        required: true
      test-command:
        description: Shell command run in command mode inside the image; must exit 0
        type: string
        default: 'true'
      push:
        description: Push, attest and sign after the tests pass
        type: boolean
        default: false

permissions:
  contents: read

env:
  TRIVY_IMAGE: aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa

jobs:
  build-test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
        with:
          driver: docker
      - name: Build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: ${{ inputs.context }}
          load: true
          tags: derived:ci
      - name: Smoke test (desktop under an arbitrary UID, then the test command)
        env:
          TEST_COMMAND: ${{ inputs.test-command }}
        run: |
          docker run -d --name derived-smoke --user 123456:0 --read-only --cap-drop ALL \
            --security-opt no-new-privileges --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 \
            --tmpfs /home/wineuser:mode=0770 --shm-size 1g derived:ci
          for _ in $(seq 300); do
            docker exec derived-smoke /usr/local/bin/desktop healthcheck >/dev/null 2>&1 && break
            sleep 1
          done
          docker exec derived-smoke /usr/local/bin/desktop healthcheck || { docker logs derived-smoke; exit 1; }
          docker rm -f derived-smoke
          docker run --rm --user 123456:0 --tmpfs /home/wineuser:mode=0770 derived:ci bash -c "$TEST_COMMAND"
      - name: Scan
        run: >-
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE"
          image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 derived:ci
      - name: Save tested image
        if: inputs.push
        run: docker save derived:ci | gzip > image.tar.gz
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        if: inputs.push
        with:
          name: derived-image
          path: image.tar.gz
          retention-days: 1

  publish:
    needs: build-test
    if: inputs.push
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    env:
      IMAGE_NAME: ${{ inputs.image-name }}
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: derived-image
      - name: Load and tag
        id: tag
        run: |
          gunzip -c image.tar.gz | docker load
          version="${GITHUB_SHA::7}"
          docker tag derived:ci "$IMAGE_NAME:$version"
          docker tag derived:ci "$IMAGE_NAME:latest"
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
          docker push "$IMAGE_NAME:latest"
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
          subject-name: ${{ inputs.image-name }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
      - uses: actions/attest-sbom@c604332985a26aa8cf1bdc465b92731239ec6b9e # v4.1.0
        with:
          subject-name: ${{ inputs.image-name }}
          subject-digest: ${{ steps.push.outputs.digest }}
          sbom-path: sbom.spdx.json
          push-to-registry: true
      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
      - name: Sign
        env:
          DIGEST: ${{ steps.push.outputs.digest }}
        run: cosign sign --yes "$IMAGE_NAME@$DIGEST"
```

- [ ] **Step 4: Add the `example` job to `ci.yml`**

Append under `jobs:`:

```yaml
  example:
    # The called workflow declares publish-job permissions; the caller must allow them even with push: false.
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: ./.github/workflows/build-derived.yml
    with:
      context: examples/notepadpp
      image-name: ghcr.io/kamphaus/docker-wine-example-notepadpp
      test-command: test -f "$WINEPREFIX/drive_c/Program Files/Notepad++/notepad++.exe"
      push: false
```

- [ ] **Step 5: Lint and commit**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
git add -A examples .github/workflows/build-derived.yml .github/workflows/ci.yml
git commit -m "feat: reusable derived-image workflow and Notepad++ example" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: actionlint prints nothing.

---

### Task 9: README, migration note, publish and pin digests (outward-facing: confirm with the user first)

**Files:**
- Modify: `README.md`, `deploy/openshift/base/kustomization.yaml`, `examples/notepadpp/Dockerfile`

**Interfaces:**
- Produces: a public, signed `ghcr.io/kamphaus/docker-wine:stable@<digest>`, which the Kustomize base and the example then pin.

- [ ] **Step 1: Rewrite `README.md`**

The README must contain these sections:
1. **What it is:** Wine on a rootless XFCE/RDP desktop (link to docker-remote-desktop); audio and clipboard; no RDP password.
2. **Security model:** the same as the base. Add that Wine is not a sandbox, and that clipboard is an accepted data-transfer channel.
3. **Local use:** `docker pull …`, `./run-local IMAGE [--ephemeral]`, connect to `127.0.0.1:3389`. Local mode is for single-user workstations.
4. **OpenShift:**
   - `oc apply -k deploy/openshift/overlays/<user>`.
   - `scripts/oc-rdp -n NS`.
   - RBAC (`desktop-user`; `edit`/`admin` also grant port-forward).
   - The optional TLS Secret `wine-desktop-tls`.
   - The `egress-deny` component.
   - Resource defaults.
5. **Derived images:**
   - The 5.1 conventions from the spec: `wine-prefix run/finalize`, `PREFIX_VERSION`, `downloads.lock` with `fetch-verified`, bind-mounting licensed installers, silent installs.
   - The Notepad++ example.
   - Calling `build-derived.yml` by SHA.
   - Extending the Renovate preset.
   - Bumping `PREFIX_VERSION` when the software changes.
6. **Prefix modes:** `PREFIX_MODE` and `PREFIX_UPGRADE` tables with every value and its behaviour.
7. **Updating the WineHQ key:** download it, check the fingerprint `D43F640145369C51D786DDEA76F1A20FF987672F` with `gpg --show-keys`, commit.
8. **Migration from scottyhardy/docker-wine:**
   - The launcher, X11 mode and `--as-root` are gone.
   - Existing `winehome` volumes need the one-time `chown` from the spec's migration note.
   - Images come from GHCR.
9. **Testing:** `tests/run IMAGE`, `tests/manifests/validate`, `tests/k8s/kind-e2e.sh IMAGE`.

- [ ] **Step 2: Run the full local verification**

```bash
BASE_IMAGE=docker-remote-desktop:local ./build -q && tests/run docker-wine:local && tests/manifests/validate
```

Expected: `all 15 test cases passed` and `PASS [manifests]`.

- [ ] **Step 3: Push and open the PR (ask the user first)**

```bash
git push -u origin feat/rootless-wine
gh pr create --base master --title "Rootless docker-wine for OpenShift with derived-image tooling" \
  --body "Implements Plan 2 of docs/superpowers/specs/2026-10-11-rootless-openshift-design.md."
```

Expected: the PR shows `build-test`, `manifests`, `kind` and `example` all passing.

- [ ] **Step 4: GitHub settings (the user does these in the web UI; list them for the user)**

1. Settings → Actions → General: enable **"Allow GitHub Actions to create and approve pull requests"**.
2. Install the Mend Renovate GitHub App on `kamphaus/docker-wine`.
3. Branch protection on `master`: require `build-test`, `manifests`, `kind` and `example`.
4. After the first publish: make the `docker-wine` package public.

- [ ] **Step 5: Pin the published digest in the Kustomize base and the example**

After merge and publish:

```bash
digest=$(docker buildx imagetools inspect ghcr.io/kamphaus/docker-wine:stable --format '{{json .Manifest.Digest}}' | tr -d '"')
sed -i "s|^    newTag: stable$|    newTag: stable\n    digest: ${digest}|" deploy/openshift/base/kustomization.yaml
sed -i "s|^ARG BASE_IMAGE=ghcr.io/kamphaus/docker-wine:stable$|ARG BASE_IMAGE=ghcr.io/kamphaus/docker-wine:stable@${digest}|" examples/notepadpp/Dockerfile
tests/manifests/validate
git commit -am "build: pin docker-wine digest in deployment and example" -m "Assisted-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `PASS [manifests]`. Renovate keeps both digests current from then on.

- [ ] **Step 6: Manual acceptance on a real OpenShift 4.22 cluster (spec test 13; the user runs this with you)**

Use a project where the user has `admin`, plus a second test user who has no role binding.

```bash
oc new-project wine-desktop-acceptance
oc apply -k deploy/openshift/base -n wine-desktop-acceptance
oc -n wine-desktop-acceptance rollout status deployment/wine-desktop --timeout=15m
oc -n wine-desktop-acceptance get pod -l app.kubernetes.io/name=wine-desktop -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
scripts/oc-rdp -n wine-desktop-acceptance -c xfreerdp
```

Record each of the following as pass or fail in the PR description:
1. The SCC annotation reads `restricted-v2`.
2. The desktop appears in the RDP client.
3. Audio plays: run `paplay /usr/share/sounds/alsa/Front_Center.wav` in an XFCE terminal, or play any sound.
4. Copy and paste works in both directions.
5. With `PREFIX_MODE=ephemeral` set via `oc set env deployment/wine-desktop PREFIX_MODE=ephemeral`, the pod restarts and becomes healthy.
6. As the second user, `oc -n wine-desktop-acceptance port-forward deployment/wine-desktop 13389:3389` is refused with `Forbidden`.

Clean up with `oc delete project wine-desktop-acceptance`.
