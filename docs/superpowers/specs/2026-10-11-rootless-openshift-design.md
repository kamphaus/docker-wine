# Rootless, OpenShift-compatible docker-wine: design

- **Date:** 2026-10-11
- **Status:** Approved design, pending implementation plan
- **Repos affected:** `kamphaus/docker-remote-desktop` (base image), `kamphaus/docker-wine` (Wine image, deployment, derived-image tooling)
- **Inputs:** `claude-analysis-rdp.md` (findings R1–R12) and `claude-analysis-wine.md` (findings W1–W16), kept next to both repos

## 1. Goals and decisions

### Goals

1. Fix every security finding in both analyses, either by fixing it, by removing the feature it belongs to, or by recording it as an accepted risk (Section 7).
2. Run docker-wine on OpenShift 4.22 under the default **`restricted-v2`** SCC with no extra grants.
3. Provide a documented, tested pattern for building images `FROM docker-wine` with Windows software pre-installed.
4. Make builds deterministic: every external input is pinned by version, commit or digest, and Renovate keeps those pins up to date.

### Decisions made during design

| Topic | Decision |
|---|---|
| Run modes | OpenShift, plus local `docker run`/`podman run` in RDP mode. X11 forwarding, `--xvfb` mode, host PulseAudio wiring and macOS XQuartz/Homebrew setup are removed. |
| OpenShift access | `oc port-forward` only. No Service, Route or LoadBalancer. |
| SCC | `restricted-v2`: arbitrary non-root UID, GID 0, no capabilities, no privilege escalation. |
| Required RDP features | Audio playback and clipboard. No drive redirection. |
| RDP login | **No password.** Access is controlled by `pods/portforward` RBAC on OpenShift and by binding to localhost when run locally. A password may be added later as an optional layer. |
| Session architecture | xrdp connects directly to a session that is already running (Xorg + xorgxrdp, chansrv, PulseAudio, XFCE), started by an unprivileged supervisor. No `xrdp-sesman`, no PAM. |
| Build and publish | GitHub Actions → GHCR (`ghcr.io/kamphaus/*`), plus local `docker build` for development. |
| Renovate | Mend-hosted GitHub App. Anything it cannot do (`postUpgradeTasks`) is done by two helper workflows. |
| Wine prefix handling | Both modes are supported through `PREFIX_MODE=seed\|ephemeral`, with `seed` as the default. |

### Non-goals

- GPU acceleration.
- Multi-user sessions or more than one desktop per container.
- An RDP password, or any authentication other than port-forward RBAC and localhost binding.
- Upstream PRs to `scottyhardy/*`.
- arm64/armv7 images (the base image becomes amd64-only because its only consumer is the amd64 Wine image).
- Wine devel builds (they can be added back later as a CI matrix entry).
- Automating interactive (non-silent) Windows installers.
- Building Wine from source.
- Bit-for-bit reproducible images. The goal is deterministic *inputs*.

## 2. Image structure and modes

```
ghcr.io/kamphaus/docker-remote-desktop   rootless XFCE + xrdp desktop, no Wine
        └─ ghcr.io/kamphaus/docker-wine  + Wine, winetricks, Gecko/Mono, wine-prefix tooling
                └─ ghcr.io/kamphaus/<app>  derived images with pre-installed software
```

Each image starts in one of two modes, chosen by the arguments it receives:

- **Desktop mode** (no arguments): starts the RDP desktop.
- **Command mode** (arguments given): sets up identity and runs the init hooks, then `exec`s the arguments as the unprivileged user without starting a desktop. CI and derived-image builds use this mode, for example `docker run IMAGE xvfb-run -a winetricks -q corefonts`.

### Removed from the repos

| Repo | Removed |
|---|---|
| docker-remote-desktop | Firefox and the Mozilla PPA; `git`, `vim` and `software-properties-common` in the final image; the `ubuntu` user and its password; `deploy`; the arm builds; `--hostname` in the helper scripts. |
| docker-wine | The 784-line `docker-wine` launcher (replaced by `run-local`); X11, Xvfb, PulseAudio and macOS code paths; `gosu`, `sudo` and creating the user at runtime; the `USER_*`, `RUN_AS_ROOT`, `FORCED_OWNERSHIP`, `RDP_SERVER`, `USE_XVFB` and `DUMMY_PULSEAUDIO` options; the `-nordp` variant; `Dockerfile.build_from_source`, `build_from_source`, `entrypoint_ci_builder.sh`, `deploy`, `hooks/`, `pulse-client.conf`; Docker Hub publishing and the Docker Hub description action. |

## 3. Rootless runtime (base image)

### 3.1 Filesystem and identity conventions

- The image ends with `USER 1001`. `/etc/passwd` contains `wineuser:x:1001:0::/home/wineuser:/bin/bash`, written at build time.
- Writable locations, all owned by group 0 with `g=u` permissions so that any UID in GID 0 can write them:
  - `/home/wineuser` (`HOME`; a volume mount in practice)
  - `/run/desktop` (all runtime state: generated configs, sockets, logs, TLS material, nss_wrapper files)
  - `/tmp`
- **Identity for arbitrary UIDs.** When the current UID has no passwd entry, the supervisor writes `passwd` and `group` files into `/run/desktop` that map the current UID to the name `wineuser` with home `/home/wineuser`. It then exports `LD_PRELOAD=libnss_wrapper.so`, `NSS_WRAPPER_PASSWD` and `NSS_WRAPPER_GROUP`. As a result the username, and with it Wine's `C:\users\wineuser`, is the same at build time and at runtime. `/etc/passwd` is never made writable.
- At build time, every file with the setuid or setgid bit is stripped: `find / -xdev -perm /6000 -type f -exec chmod a-s {} +`.
- At build time, these are deleted: `/etc/xrdp/cert.pem`, `/etc/xrdp/key.pem`, `/etc/xrdp/rsakeys.ini`, `/etc/ssl/private/ssl-cert-snakeoil.key`, `/etc/ssl/certs/ssl-cert-snakeoil.pem`.

### 3.2 Supervisor

- `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/desktop"]`. `tini` is PID 1 and runs `desktop` (bash). Derived images inherit this entrypoint and must not override it.
- `desktop` with no arguments starts desktop mode. `desktop <cmd…>` runs command mode. `desktop healthcheck` runs the probe, so `healthcheck` is a reserved first argument.
- The tmpfs mounts in `run-local` are created group-0 writable (`mode=0770` for `/run/desktop`), because a fresh tmpfs is otherwise owned by root and not writable by UID 1001.

Desktop-mode sequence:

1. **Identity and runtime directories.** As in 3.1. Fail fast if `/run/desktop` or `$HOME` is not writable, with a message naming the path.
2. **TLS.** If `/etc/desktop/tls/tls.crt` and `/etc/desktop/tls/tls.key` exist (for example a mounted `kubernetes.io/tls` Secret), use them. Otherwise generate a new self-signed RSA-3072 or ECDSA P-256 pair into `/run/desktop/tls/` on every start.
3. **Init hooks.** Source every `/etc/desktop/init.d/*.sh` in lexical order. Because they are sourced, the variables they export (for example `WINEPREFIX`) reach the session. A hook that fails aborts startup.
4. **Session components**, all running as the current UID:
   - `Xorg :10` using the xorgxrdp config, with `-nolisten tcp -noreset`, logging to `/run/desktop/log/`, and `XRDP_SOCKET_PATH=/run/desktop/xrdp`.
   - `xrdp-chansrv` with `DISPLAY=:10`.
   - PulseAudio in user mode with `--exit-idle-time=-1`, loading `module-xrdp-sink` and `module-xrdp-source`.
   - `dbus-launch --exit-with-session startxfce4`.
5. **xrdp.** Start `xrdp --nodaemon` with a generated `/run/desktop/xrdp.ini`:
   - Exactly one session section: `lib=libxup.so`, `port=` set to the fixed display-10 socket (so sesman is not involved), and `chansrvport=` set (so audio and clipboard work).
   - `security_layer=tls`, `ssl_protocols=TLSv1.2, TLSv1.3`, and `certificate`/`key_file` pointing at the TLS material from step 2.
   - `address=${RDP_LISTEN_ADDRESS:-127.0.0.1}` and `port=3389`.
   - The login screen is skipped (`autorun` set to the single session). Drive redirection is disabled (`rdpdr=false`). Clipboard (`cliprdr=true`) and audio (`rdpsnd=true`) are enabled.
   - PID file and logs under `/run/desktop`. Logs go to stdout.
6. **Supervision.** `wait -n`. If any component exits, the supervisor terminates the remaining ones (TERM, then KILL after 10 seconds) and exits non-zero, and the container runtime restarts the container. SIGTERM to the container stops everything cleanly and exits 0.

Session behaviour:

- When an RDP client disconnects, nothing stops, and reconnecting resumes the same desktop.
- A second client that connects takes over the session.

`desktop healthcheck` exits 0 when the Xorg socket for display 10 exists and a TCP connection to `127.0.0.1:3389` succeeds. It uses bash `/dev/tcp`, so no extra tools are needed.

### 3.3 Configuration (environment)

| Variable | Default | Purpose |
|---|---|---|
| `RDP_LISTEN_ADDRESS` | `127.0.0.1` | xrdp bind address. `run-local` sets `0.0.0.0` inside the container. |
| `TZ` | `UTC` | Timezone, set through the `TZ` environment variable only (`/etc/localtime` is not touched). |
| `PREFIX_MODE` | `seed` | Wine image only; see Section 5. |
| `PREFIX_UPGRADE` | `fail` | Wine image only; see Section 5. |

### 3.4 Items to verify first (milestone M0)

The design relies on two behaviours confirmed in the xrdp v0.10.4.1 source:

- A session `port` other than `-1` skips sesman (`xrdp/xrdp_mm.c:3133`).
- Setting `chansrvport` attaches chansrv even without sesman (`xrdp/xrdp_mm.c:3167-3178`).

M0 checks the following on Ubuntu noble's packaged xrdp 0.9.24 running under an arbitrary UID:

1. Direct connect plus `chansrvport` works, and audio and clipboard both reach an RDP client.
2. xrdp's PID file, log and socket paths can all be moved under `/run/desktop`.
3. Xorg's compiled keymap output (`/var/lib/xkb`) behaves correctly under a read-only root filesystem.

Decision rules:

- If check 1 or 2 fails on 0.9.24, the base image builds xrdp and xorgxrdp from a pinned 0.10.x tag and commit in a builder stage, using the same pinning pattern as pulseaudio-module-xrdp (Section 6).
- If check 3 fails, `/var/lib/xkb` is made group-0 writable, and `readOnlyRootFilesystem` is dropped from the OpenShift manifest and from `run-local`.

## 4. Deployment

### 4.1 OpenShift (`deploy/openshift/` in docker-wine, Kustomize)

- **Workload:** a `Deployment` with `replicas: 1` and `strategy: Recreate`, because the RWO home PVC cannot be attached twice during a rolling update. One desktop per user. Users or teams are separated by namespace or by an overlay (`namePrefix`, PVC size).
- **Pod security:**
  - No `runAsUser`; the SCC assigns the UID and `fsGroup`.
  - `runAsNonRoot: true`, `seccompProfile.type: RuntimeDefault`.
  - In the container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true` (subject to M0).
  - `automountServiceAccountToken: false`, `enableServiceLinks: false`.
- **Volumes:**

  | Volume | Mount | Notes |
  |---|---|---|
  | PVC `home` (RWO, default 20Gi) | `/home/wineuser` | Also holds the Wine prefix in seed mode. |
  | `emptyDir` (`medium: Memory`, `sizeLimit: 1Gi`) | `/dev/shm` | Replaces `--shm-size`. |
  | `emptyDir` | `/tmp` and `/run/desktop` | |
  | `emptyDir` | `/run/wine-prefix` | Only used in ephemeral mode. |
  | Secret (optional, `kubernetes.io/tls`) | `/etc/desktop/tls` | For example issued by cert-manager. |

- **Env:** `RDP_LISTEN_ADDRESS=127.0.0.1` (set explicitly), `PREFIX_MODE`, `PREFIX_UPGRADE`, `TZ`.
- **Scheduling:** `nodeSelector: kubernetes.io/arch: amd64`. Requests 2 CPU / 4Gi, limits 4 CPU / 8Gi, overridable in overlays.
- **Probes:** startup and liveness probes `exec` `desktop healthcheck`. Kubelet TCP probes cannot be used because they connect to the pod IP and xrdp listens only on loopback.
- **Image:** referenced by digest, with an `imagePullSecrets` entry for private GHCR packages.
- **Network:** no `Service`. A `NetworkPolicy` denies all ingress to the pod. This does not affect port-forward, which reaches the pod's loopback through the kubelet. An opt-in Kustomize component, `components/egress-deny`, denies egress and includes an example allowlist; without it, egress is left open.
- **RBAC:** a `desktop-user` Role grants `get`/`list` on `pods` and `create` on `pods/portforward`. An example RoleBinding is included. The docs state that this Role, or the built-in `edit`/`admin` roles that also contain port-forward, is the effective access boundary.
- **Connecting:** `scripts/oc-rdp [-n NAMESPACE] [DEPLOYMENT] [LOCAL_PORT]` runs `oc port-forward deploy/<name> <port>:3389` in a reconnect loop, prints the target, and optionally launches `xfreerdp`/`mstsc` against `localhost:<port>`. The self-signed certificate warning is expected unless a TLS Secret is mounted.

### 4.2 Local (`run-local` in docker-wine)

```
run-local IMAGE [--name NAME] [--home-volume VOLUME] [--port PORT] [--ephemeral]
```

It runs the equivalent of the command below, auto-detecting `docker` or `podman`:

```bash
docker run -d --name NAME --user 1001:0 --cap-drop ALL \
  --security-opt no-new-privileges --read-only \
  --tmpfs /tmp:mode=1777 --tmpfs /run/desktop:mode=0770 --shm-size 1g \
  -v VOLUME:/home/wineuser -e RDP_LISTEN_ADDRESS=0.0.0.0 \
  -p 127.0.0.1:PORT:3389 IMAGE
```

- `--ephemeral` adds `-e PREFIX_MODE=ephemeral` and an anonymous volume at `/run/wine-prefix`. It deliberately does not use tmpfs, because a prefix can be several GB.
- `run-local` never pulls implicitly and requires an explicit image reference.
- The README documents `--user 123456:0` as a way to exercise the arbitrary-UID path locally, and states that local mode is intended for single-user workstations (see Section 7.3).

## 5. Derived images with pre-installed software

### 5.1 Build-time tooling (shipped in docker-wine)

- **Template prefix:** `/opt/wine/prefix-template`, with `WINEARCH=win64`. It is never used in place at runtime, because Wine refuses to run in a prefix not owned by the current UID.
- **`wine-prefix run -- CMD…`:** runs `CMD` with `WINEPREFIX=/opt/wine/prefix-template` under `xvfb-run -a`, then `wineserver -w`. The first call initialises the template with `wineboot -i`.
- **`wine-prefix finalize`:**
  - Stops wineserver.
  - Deletes `drive_c/windows/temp/*`, `drive_c/users/*/Temp/*`, Wine debug logs and winetricks caches.
  - Points the user shell folders (Documents, Desktop, Downloads) at `/home/wineuser/<Folder>`.
  - Applies `chmod -R g=u` to the template.
  - Writes `$PREFIX_VERSION` to `/opt/wine/prefix-template/.prefix-version`. It fails if `PREFIX_VERSION` is unset.
- **`fetch-verified LOCKFILE DESTDIR`:** downloads every entry in a `downloads.lock` over HTTPS and verifies its SHA-256. Any mismatch is fatal.
- **`downloads.lock` format:** one entry per line, `NAME VERSION URL sha256:HEX`, where `URL` may contain `{version}`. A `# renovate: datasource=… depName=…` comment above an entry lets Renovate bump `VERSION`. docker-wine's Gecko/Mono pins (`addons.lock`) use this same format.
- **Installer sources:**
  1. `downloads.lock` plus `fetch-verified`.
  2. For licensed or non-public installers, `RUN --mount=type=bind,source=installers,target=/installers`, so the installer never ends up in a layer.
  3. Installs must be silent (`/S`, `/qn`, `winetricks -q`, `wine regedit /S file.reg`).
- **Version:** `PREFIX_VERSION` is set explicitly by the derived Dockerfile (for example `notepadpp-8.8.1-1`). A base-image digest bump alone does not change it.
- **Optional autostart:** a standard XDG file, `/etc/xdg/autostart/<app>.desktop`.

Example (`examples/notepadpp/`, also used as the CI test of the pattern):

```dockerfile
FROM ghcr.io/kamphaus/docker-wine:<wine-version>-<shortsha>@sha256:<digest>
ENV PREFIX_VERSION=notepadpp-8.8.1-1
RUN --mount=type=bind,source=downloads.lock,target=/tmp/downloads.lock \
    fetch-verified /tmp/downloads.lock /tmp/dl \
 && wine-prefix run -- winetricks -q corefonts \
 && wine-prefix run -- wine /tmp/dl/npp-installer.exe /S \
 && wine-prefix finalize \
 && rm -rf /tmp/dl
COPY notepadpp.desktop /etc/xdg/autostart/
```

### 5.2 Runtime: the `/etc/desktop/init.d/50-wine-prefix.sh` hook

- **No template present** (plain docker-wine): export `WINEPREFIX=$HOME/.wine`; Wine creates the prefix on first use. `PREFIX_MODE` is ignored.
- **`PREFIX_MODE=seed`** (default). The prefix is `$HOME/.wine`.
  - If it is missing: `cp -a --no-preserve=ownership` the template into it, so the files are owned by the runtime UID.
  - If its `.prefix-version` equals the image's version: use it.
  - If the versions differ, act on `PREFIX_UPGRADE`:
    - `fail` (default): exit non-zero with `prefix version <old> does not match image version <new>; set PREFIX_UPGRADE=reseed or keep`.
    - `reseed`: move the old prefix to `$HOME/.wine.bak-<old>` (replacing any earlier backup), then copy the template.
    - `keep`: use the old prefix and log a warning.
- **`PREFIX_MODE=ephemeral`:**
  - The docker-wine image creates `/run/wine-prefix` owned by group 0 with `g=u`, so a fresh anonymous Docker volume mounted there inherits writable permissions. On OpenShift, the `emptyDir` is writable through `fsGroup`.
  - Copy the template into `/run/wine-prefix` on every start and export `WINEPREFIX=/run/wine-prefix`. Log how long the copy took.
  - User files persist because the shell folders point into `$HOME` (5.1).
- **Any other value** of `PREFIX_MODE` or `PREFIX_UPGRADE` makes the hook exit non-zero with the list of valid values.

### 5.3 Derived-image CI

A reusable workflow, `kamphaus/docker-wine/.github/workflows/build-derived.yml`, called by commit SHA. Inputs: `context`, `image-name`, and an optional `test-command`. It runs the same pipeline as the base images (Section 6.4): build → smoke test (desktop healthcheck, then `test-command` in command mode) → Trivy → push to GHCR → attest → sign. App repos extend the Renovate preset `github>kamphaus/docker-wine//renovate/preset`.

## 6. Deterministic builds, updates and CI

### 6.1 Pin inventory

| Input | Pin form | Updated by |
|---|---|---|
| `ubuntu` base image | `ubuntu:24.04@sha256:…` | Renovate (Dockerfile manager, `docker:pinDigests`) |
| Ubuntu apt packages, including the deb-src that pulseaudio-module-xrdp builds against | `ARG UBUNTU_SNAPSHOT=YYYYMMDDTHHMMSSZ`, written as `Snapshot:` into `/etc/apt/sources.list.d/ubuntu.sources` (deb and deb-src) | `snapshot-bump.yml` (6.3) |
| pulseaudio-module-xrdp | `ARG` tag plus commit SHA; the build clones the tag and fails if `git rev-parse HEAD` ≠ SHA | Renovate regex manager, `github-tags` with `currentDigest` |
| xrdp/xorgxrdp (only if M0 requires a source build) | Same as pulseaudio-module-xrdp | Same |
| WineHQ repository key | Keyring committed to the repo, referenced with `signed-by=`; its fingerprint is checked at build time | Manually |
| Wine | `ARG WINE_VERSION`; `winehq-stable`, `wine-stable`, `wine-stable-amd64` and `wine-stable-i386:i386` all pinned to `=${WINE_VERSION}` | Renovate `deb` datasource, `registryUrl=https://dl.winehq.org/wine-builds/ubuntu?suite=noble&components=main&binaryArch=amd64` |
| winetricks | Release tag plus commit SHA, downloaded from `https://raw.githubusercontent.com/Winetricks/winetricks/<sha>/src/winetricks` (the commit SHA fixes the content) | Renovate `github-tags` with `currentDigest` |
| Gecko/Mono MSIs | `addons.lock` (5.1 format) | `renovate-fixup.yml` (6.3) |
| GitHub Actions | Commit SHA plus a `# vX.Y.Z` comment | Renovate `helpers:pinGitHubActionDigests` |
| docker-wine's base image | `FROM ghcr.io/kamphaus/docker-remote-desktop:<tag>@sha256:…` | Renovate (docker datasource on GHCR) |
| Derived images' base | `FROM ghcr.io/kamphaus/docker-wine:<tag>@sha256:…` | Renovate (via the preset) |

The pulseaudio-module-xrdp builder stage copies only the two module `.so` files and the autostart `.desktop` entry into the final image. It no longer copies the whole `/tmp/install` tree to `/`.

### 6.2 Renovate configuration (`renovate.json` in each repo, plus `renovate/preset.json` in docker-wine)

- **Extends:** `config:recommended`, `docker:pinDigests`, `helpers:pinGitHubActionDigests`, `:semanticCommits`.
- **One generic regex custom manager** for files matching `(^|/)Dockerfile$` and `(^|/)[^/]+\.lock$`. It matches:
  ```
  # renovate: datasource=<ds> depName=<name>[ registryUrl=<url>][ versioning=<v>]
  ARG <NAME>_VERSION=<currentValue>
  [ARG <NAME>_COMMIT=<currentDigest>]
  ```
  and the equivalent `downloads.lock` line form.
- **Package rules:**
  - Group all GitHub Actions updates into one PR.
  - Automerge digest-only updates (base image digests, action digests) once CI passes.
  - Never automerge `WINE_VERSION` or any major update.
  - Label every Renovate PR `dependencies`.
- **Schedule and alerts:** weekly schedule (`before 6am on monday`), `vulnerabilityAlerts` enabled.
- **Preset:** `renovate/preset.json` contains the custom manager and package rules, so the base repos and derived repos all share them.

### 6.3 Helper workflows (needed because the hosted Renovate app cannot run `postUpgradeTasks`)

- **`renovate-fixup.yml`** (docker-wine and derived repos):
  - Trigger: `pull_request` from `renovate/*` branches in the same repo, when `Dockerfile` or any `*.lock` changes.
  - Runs `scripts/update-downloads`:
    - For docker-wine, it first runs `scripts/update-addons <wine-version>`, which reads `dlls/appwiz.cpl/addons.c` at tag `wine-<version>` to find the Gecko/Mono versions that Wine release expects and rewrites `addons.lock`.
    - It then re-downloads every `downloads.lock`/`addons.lock` entry whose version changed and rewrites its SHA-256.
  - Commits any changes to the PR branch with `GITHUB_TOKEN`, then triggers `ci.yml` for the new head commit with `workflow_dispatch` (commits made with `GITHUB_TOKEN` do not trigger `pull_request` workflows).
  - Permissions: `contents: write`, `actions: write`.
- **`snapshot-bump.yml`** (both repos): runs on a weekly cron and on `workflow_dispatch`. It sets `UBUNTU_SNAPSHOT` to the current UTC date at `T000000Z` and opens a PR. **This PR is the security-patching cadence for Ubuntu packages.**

### 6.4 CI (`ci.yml`, same shape in both repos)

- **Triggers:** `pull_request`, push to `master`, and `workflow_dispatch`. There is no scheduled rebuild; updates arrive only as PRs.
- **Steps:**
  1. Build once with buildx, loaded into the runner's docker.
  2. Run `tests/run <image>`.
  3. Trivy scan, failing on fixable CRITICAL vulnerabilities.
  4. On `master` only: push the tested image to GHCR, generate SBOM and provenance attestations, sign with cosign keyless (GitHub OIDC), and write the digest to the job summary.
- **Permissions:** top-level `contents: read`. The publish job alone gets `packages: write`, `id-token: write` and `attestations: write`. GHCR login happens immediately before the push and uses `GITHUB_TOKEN`.
- **Concurrency:** a concurrency group per ref cancels superseded runs.
- **Tags** (consumers pin by digest):
  - Base: `noble-<YYYYMMDD>-<shortsha>` plus a moving `noble` tag.
  - Wine: `<wine-version>-<shortsha>` plus a moving `stable` tag.
- **Pull requests in docker-wine** also run `build-derived.yml` on `examples/notepadpp` (push disabled) and the kind cluster test (test 12).

## 7. Security findings and their outcomes

### 7.1 Runtime

| Finding | Outcome |
|---|---|
| W1, R1, R2: known password plus sudo; 3389 reachable on all interfaces | **Removed/fixed.** No accounts, passwords or sudo. xrdp binds to `127.0.0.1` by default. OpenShift has no Service; `run-local` publishes only on `127.0.0.1`. |
| W2, R5: public sudo password; everything runs as root | **Fixed.** No root processes, and xrdp handles network input before login as an unprivileged user. setuid/setgid bits are stripped. Capabilities are dropped and privilege escalation is blocked by both restricted-v2 and `run-local`. |
| W3–W6: X11 cookie, anonymous PulseAudio socket, macOS PulseAudio rw mount, XQuartz/Homebrew | **Removed** together with X11 mode and the launcher. |
| W7: recursive `chown` of root-owned host directories | **Removed.** No `chown` at runtime. |
| W8: MD5-crypt hashes, passwords in env and `ps` | **Removed.** No passwords. |
| W9: mutable `:latest` pulled on every run | **Fixed.** Digest references everywhere; `run-local` never pulls implicitly. |
| R3: TLS key shared by every copy of the image | **Fixed.** The image contains no key material; a key is generated per start or mounted. |
| R4: legacy RDP security layer | **Fixed.** `security_layer=tls`, TLS 1.2 and 1.3 only. |
| R6: no lockout; logs inside the container | **N/A / fixed.** No password to brute-force. xrdp logs go to stdout. |
| R7: host hostname leaked; extra tools; weak hashing | **Fixed.** No `--hostname`; tools removed; no hashing. |
| New: drive redirection as an exfiltration path | **Disabled.** |

### 7.2 Build and CI

| Finding | Outcome |
|---|---|
| W10: Gecko/Mono over HTTP with no checksum | **Fixed.** HTTPS plus SHA-256 (`addons.lock`). |
| W11: `git://` clone of an unpinned master | **Removed.** Building from source is out of scope. |
| W12, R8, R10: unpinned inputs | **Fixed** (6.1). Builder-stage `COPY` narrowed. |
| W13: `apt-key add` | **Fixed.** Committed keyring with `signed-by=` and a fingerprint check. |
| R9: PPA pinned with `Package: *` | **Removed** together with Firefox. |
| W14, R11: third-party action running with registry credentials; actions pinned by tag | **Fixed.** `haya14busa/action-cond` replaced by a shell step; all actions SHA-pinned; least-privilege `GITHUB_TOKEN`; login immediately before the push. |
| W15: Docker Hub password given to the description action | **Removed.** No Docker Hub. |
| W16: pushed image is not the tested image | **Fixed.** Build once, test, push the same image. |
| R11: no scanning or signing | **Added.** Trivy, SBOM and provenance attestations, cosign signing. |
| R12: dead `deploy` script | **Deleted** in both repos, together with `hooks/`. |

### 7.3 Accepted risks (documented in both READMEs)

- **No RDP password:** anyone allowed to port-forward to the pod gets the desktop. Mitigation: one namespace per user or team, and grant `pods/portforward` deliberately.
- **Local mode on a shared host:** every local user can reach `127.0.0.1:PORT`. Local mode is for single-user workstations.
- **Clipboard:** a data transfer channel, kept because it is a requirement.
- **Ubuntu security fixes arrive weekly**, through the snapshot bump PR, not continuously.
- **Licensed software in derived images:** keep those GHCR packages private and give OpenShift a pull secret.

## 8. Testing

`tests/run <image>` is a bash test runner, used unchanged locally and in CI.

**Base image**

1. With `--user 123456:0 --read-only --cap-drop ALL --security-opt no-new-privileges` and the tmpfs/volume mounts from 4.2, `desktop healthcheck` succeeds within 60 seconds.
2. No process in the container runs as UID 0, and `find / -xdev -perm /6000 -type f` finds nothing.
3. Two containers started from the same image present different TLS certificate fingerprints.
4. With default settings, xrdp listens only on `127.0.0.1:3389`, checked via `/proc/net/tcp`.
5. **End to end:** a test container sharing the network namespace runs `xfreerdp` under Xvfb against `127.0.0.1:3389`. Pass criteria:
   - The session connects.
   - The xrdp log shows chansrv attached.
   - `pactl list short sinks` shows `xrdp-sink`.
6. Command mode under an arbitrary UID: `id -un` prints `wineuser`, and `echo $HOME` prints `/home/wineuser`.

**docker-wine**

7. `wineboot -i` in a fresh prefix leaves Gecko and Mono installed: their install directories exist and their uninstall registry entries are present.
8. `winetricks -q` runs one verb successfully. This test needs network access and is kept from the previous CI.
9. Prefix modes, using the `examples/notepadpp` image:
   - **Seed:** the first start creates `$HOME/.wine` with the right `.prefix-version`, and a restart does not copy again (the timestamp is unchanged).
   - **Upgrade:** an image built with a different `PREFIX_VERSION` and `PREFIX_UPGRADE=fail` exits non-zero with the expected message. `reseed` leaves `$HOME/.wine.bak-<old>`. `keep` starts and logs a warning.
   - **Ephemeral:** `WINEPREFIX=/run/wine-prefix`, and the Documents shell folder resolves into `/home/wineuser`.
   - **Invalid values:** an invalid `PREFIX_MODE` exits non-zero.
10. Under `--user 123456:0`, `wine cmd /c ver` succeeds, which shows Wine's prefix-ownership check passes.

**OpenShift manifests**

11. `kustomize build` succeeds for the base, the overlay and the `egress-deny` component, and `kubeconform` (with OpenShift schemas) validates the output.
12. **kind cluster test** (PRs only):
    - Namespace labelled `pod-security.kubernetes.io/enforce=restricted`, with the overlay patched to `runAsUser: 1000700000` and `fsGroup: 1000700000` to approximate restricted-v2.
    - Deploy the base image, wait for readiness, then `kubectl port-forward` and repeat test 5 through the tunnel.
13. **Manual checklist** on a real OpenShift 4.22 cluster before the first release:
    - Deploy and connect with `oc-rdp`.
    - Check audio and clipboard.
    - Check both prefix modes.
    - Check that a pod without `desktop-user` RBAC cannot be port-forwarded to.

## 9. Milestones

| | Scope | Repo | Done when |
|---|---|---|---|
| M0 | Verification checks from 3.4 | docker-remote-desktop (throwaway branch) | The decision between packaged xrdp 0.9.24 and a pinned 0.10.x source build, and the outcome for `readOnlyRootFilesystem`, are recorded in this spec. |
| M1 | Rootless base: supervisor, nss_wrapper, TLS generation, generated `xrdp.ini`, setuid stripping, removals, pinning, Renovate, `snapshot-bump.yml`, `ci.yml` | docker-remote-desktop | Tests 1–6 pass in CI, and the image is published to GHCR. |
| M2 | Wine on the new base: Wine/winetricks/addons pinning, committed keyring, `fetch-verified`, `wine-prefix`, the prefix hook, `run-local`, removals, Renovate, `renovate-fixup.yml`, `snapshot-bump.yml`, `ci.yml`, migration note | docker-wine | Tests 7, 8 and 10 pass in CI (test 9 needs the M4 example image), and the image is published. |
| M3 | OpenShift: Kustomize base and overlay, `egress-deny` component, RBAC, NetworkPolicy, `oc-rdp` | docker-wine | Tests 11 and 12 pass, and checklist 13 is done. |
| M4 | Derived images: `build-derived.yml`, `examples/notepadpp`, `renovate/preset.json` | docker-wine | Test 9 passes, and the example is built on every PR. |

Each milestone also updates the affected README.

**Migration note (M2):** existing `winehome` volumes contain prefixes owned by UID 1010. Before use with the new image, either:

- re-own them once:
  ```bash
  docker run --rm --user 0 -v winehome:/home/wineuser IMAGE \
    chown -R 1001:0 /home/wineuser
  ```
- or recreate the volume.
