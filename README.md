# docker-wine

Wine and winetricks on a rootless XFCE desktop that you reach over RDP. It runs as an unprivileged user (uid 1001, group 0), so it works on OpenShift under the `restricted-v2` SCC as well as with plain Docker.

It is built on [docker-remote-desktop](https://github.com/kamphaus/docker-remote-desktop) (`ghcr.io/kamphaus/docker-remote-desktop`), which provides the rootless XFCE/xrdp desktop with audio and clipboard redirection. Drive redirection is disabled. **There is no RDP password.**

This is a fork of [scottyhardy/docker-wine](https://github.com/scottyhardy/docker-wine); see [Migration](#migration-from-scottyhardydocker-wine).

## Security model

The security model is the base image's, plus the following.

- **No RDP password.** Whoever can reach port 3389 gets the desktop. Locally the port is published on `127.0.0.1` only. On OpenShift it is reachable only through `oc port-forward` (RDP listens on the pod's loopback and all ingress is denied).
- **Local mode is for single-user workstations.** Any local user or process can connect to `127.0.0.1:3389`.
- **Wine is not a sandbox.** Windows programs run with the full rights of the container user. Isolate them with the container, network policy and namespace, not with Wine.
- **The clipboard is a data channel.** Copy and paste between client and desktop is an accepted way for data to move in both directions.
- **Ubuntu security fixes** arrive through the base image's weekly apt snapshot bump, not through `apt upgrade` at runtime.

## Local use

```bash
docker pull ghcr.io/kamphaus/docker-wine:stable
./run-local ghcr.io/kamphaus/docker-wine:stable            # prefix persisted in the "winehome" volume
./run-local ghcr.io/kamphaus/docker-wine:stable --ephemeral # fresh prefix on every start
```

Connect an RDP client to `127.0.0.1:3389` (self-signed certificate, no password). Options: `--name`, `--home-volume`, `--port`. `run-local` never pulls images implicitly, and starts the container as uid 1001 with all capabilities dropped, `no-new-privileges` and a read-only root filesystem. To mimic OpenShift's arbitrary uid, run the image with `--user 123456:0` (any uid with group 0; the home volume must be writable by group 0).

Commands run through the entrypoint's command mode, for example `docker run --rm IMAGE wine --version`. Note that `docker exec` (and `oc exec`) bypass the entrypoint hooks, so `WINEPREFIX` is not set there in ephemeral mode: `export WINEPREFIX=/run/wine-prefix/prefix` first.

## OpenShift

Manifests are in `deploy/openshift/`:

- `base`: Deployment (`Recreate`, 1 replica, restricted pod/container security context, no service account token, RDP bound to `127.0.0.1`), a 20Gi RWO home PVC, a deny-all-ingress NetworkPolicy and the `desktop-user` Role. There is deliberately no Service or Route.
- `components/egress-deny`: optional NetworkPolicy that denies all egress except cluster DNS. Add allow rules for license servers and the like.
- `overlays/example-user`: a per-user example with `namePrefix`, an `app.kubernetes.io/instance` selector label, a RoleBinding, the egress-deny component, a larger PVC and `imagePullSecrets: ghcr-pull` (for private derived images: `oc create secret docker-registry ghcr-pull ...`). Copy it for each user.

```bash
cp -r deploy/openshift/overlays/example-user deploy/openshift/overlays/alice
# edit overlays/alice: kustomization.yaml (namePrefix: alice-, the app.kubernetes.io/instance label)
# and rolebinding.yaml (the subject user name)
oc new-project wine-alice
oc apply -k deploy/openshift/overlays/alice -n wine-alice
scripts/oc-rdp -n wine-alice -c xfreerdp alice-wine-desktop   # or -c mstsc; omit -c to connect your own client to localhost:13389
```

The Deployment is named `<namePrefix>wine-desktop`, so with `namePrefix: alice-` it is `alice-wine-desktop` (the PVC is `alice-wine-desktop-home`, the Role `alice-desktop-user`). `scripts/oc-rdp [-n NAMESPACE] [-c xfreerdp|mstsc] [DEPLOYMENT] [LOCAL_PORT]` keeps an `oc port-forward` tunnel up (defaults: `wine-desktop`, port 13389), so pass the prefixed name for an overlay with a prefix.

**Access control.** Port-forwarding to a desktop is the only way in, and the Role `desktop-user` grants exactly that (`get`/`list` pods, `get`/`create` `pods/portforward`, `get` deployments). The built-in `edit` and `admin` roles also allow port-forwarding. The **namespace is the access boundary**: every holder of `desktop-user`, `edit` or `admin` in a namespace can open every desktop in it, so use one namespace per user.

**TLS.** RDP uses a self-signed certificate unless you create an optional `kubernetes.io/tls` Secret named `wine-desktop-tls` (for example from cert-manager); it is mounted at `/etc/desktop/tls`.

**Resources.** Requests 2 CPU / 4Gi, limits 4 CPU / 8Gi, 1Gi in-memory `/dev/shm`, 20Gi home volume. Patch them in your overlay. Seeding a large prefix can take minutes; the startup probe allows 10 minutes.

## Prefix modes

The Wine prefix is created at image build time as a template in `/opt/wine/prefix-template` and is never used in place (Wine refuses prefixes not owned by the running uid; the tool copies the template as the runtime uid). Images without a template (plain docker-wine) just get `$HOME/.wine`, created on demand, and ignore `PREFIX_MODE` (`PREFIX_UPGRADE` is still validated, so an invalid value is an error).

`PREFIX_MODE`:

| Value | Behaviour |
|---|---|
| `seed` (default) | The prefix is `$HOME/.wine` on the persistent home volume. If missing it is copied from the template into `$HOME/.wine.partial` and renamed when complete (a leftover `.partial` is deleted at the next start). |
| `ephemeral` | `WINEPREFIX=/run/wine-prefix/prefix`, a fresh copy of the template at every start. Needs a writable volume at `/run/wine-prefix` (an `emptyDir` on OpenShift, `-v /run/wine-prefix` with Docker; `run-local --ephemeral` does this). |

`PREFIX_UPGRADE` applies in seed mode when the prefix's `.prefix-version` differs from the image's:

| Value | Behaviour |
|---|---|
| `fail` (default) | Refuse to start with `prefix version <old> does not match image version <new>`. |
| `reseed` | Keep the old prefix as `$HOME/.wine.bak-<old version>` (sanitised) and seed a new one from the template. |
| `keep` | Keep using the old prefix and log a warning. |

Any other value of either variable is an error. Only Documents, Desktop and Downloads persist across a reseed (they point into `$HOME`); everything else in the old prefix stays in the backup. A reseed replaces an existing `.wine.bak-<old>` of the same name, and leaving `PREFIX_UPGRADE=reseed` set accumulates backups of every version change, so unset it after the upgrade. In ephemeral mode everything except those folders is lost at every restart.

## Derived images

Pre-install software into the template prefix with the build tools shipped in this image:

- `wine-prefix run -- CMD...` runs `CMD` against the template prefix under Xvfb (the first call initialises it).
- `wine-prefix finalize` cleans temp files and caches, points the shell folders into `/home/wineuser`, makes the template group-writable and writes `$PREFIX_VERSION` into it. It fails if `PREFIX_VERSION` is unset or does not match `^[A-Za-z0-9._+-]+$`.
- `fetch-verified LOCKFILE DESTDIR` downloads every entry of a `downloads.lock` over HTTPS and checks its SHA-256; a mismatch is fatal. Lines are `NAME VERSION URL sha256:HEX`, where `URL` may contain `{version}`; a `# renovate: datasource=... depName=...` comment above a line lets Renovate bump it (`scripts/update-downloads` rehashes `sha256:pending` entries and, with `--base REF`, entries whose version changed against `REF`; all others are verified and a mismatch fails).
- Licensed or non-public installers: `RUN --mount=type=bind,source=installers,target=/installers ...`, so they never end up in a layer.
- Installs must be silent (`/S`, `/qn`, `winetricks -q`, `wine regedit /S file.reg`). An autostart entry is a standard `/etc/xdg/autostart/<app>.desktop`.

**Set `PREFIX_VERSION` explicitly and bump it whenever the installed software changes** (for example `notepadpp-8.9.8.1-1` to `-2`). Renovate bumps `downloads.lock` but not `PREFIX_VERSION`, and a base-image digest bump alone does not change it. Existing seed-mode prefixes then need `PREFIX_UPGRADE=reseed` or `keep`.

[`examples/notepadpp`](examples/notepadpp) is a complete example and also the CI test of the pattern:

```dockerfile
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

**CI.** Call the reusable workflow by commit SHA:

```yaml
jobs:
  image:
    # The called workflow's publish job declares these; the caller must grant them even with push: false.
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: kamphaus/docker-wine/.github/workflows/build-derived.yml@<commit-sha>
    with:
      context: .
      image-name: ghcr.io/<owner>/myapp
      test-command: wine --version
      push: ${{ github.ref == 'refs/heads/main' }}
```

Inputs: `context` (default `.`), `image-name` (required), `test-command` (run in command mode, must exit 0), `push` (push, attest and sign after tests pass), and for testing against a locally built base `base-image-artifact`, `base-image` and `artifact-name` (unique per call). It builds, smoke-tests, scans with Trivy, then pushes, attests and signs.

**Renovate.** Extend the shared preset in your `renovate.json`:

```json
{ "extends": ["github>kamphaus/docker-wine//renovate/preset"] }
```

## Accepted risks of derived images

- Signatures and provenance attestations are written to the public Sigstore/Rekor transparency log, which exposes the image name and digest even for private images.
- The ephemeral prefix `emptyDir` has no size limit, so a runaway prefix fills the node's disk. Set a `sizeLimit` (or a quota) on multi-tenant clusters.

## Updating the WineHQ key

The repository key is committed as `winehq-archive.asc` and referenced with `Signed-By:`. To update it:

```bash
curl -fsSLo winehq-archive.asc https://dl.winehq.org/wine-builds/winehq.key
gpg --show-keys --with-fingerprint winehq-archive.asc   # must show D43F640145369C51D786DDEA76F1A20FF987672F
```

Only commit it if the fingerprint matches (or you have verified a deliberate key rotation from WineHQ).

## Migration from scottyhardy/docker-wine

- The `docker-wine` launcher script, X11-forwarding mode and `--as-root` are gone. Run the desktop with `run-local` (or on OpenShift) and connect with RDP.
- Images come from GHCR (`ghcr.io/kamphaus/docker-wine`), not Docker Hub.
- Existing `winehome` volumes are owned by uid 1010. The base image refuses to start with `/home/wineuser is not writable by uid ...`. Fix this once, or recreate the volume:

```bash
docker run --rm --user 0 --entrypoint chown -v winehome:/home/wineuser \
  ghcr.io/kamphaus/docker-wine:stable -R 1001:0 /home/wineuser
```

## Testing

```bash
./build -q                                    # builds docker-wine:local
tests/run docker-wine:local                   # all cases in tests/cases (or: tests/run IMAGE tests/cases/NAME.sh ...)
tests/manifests/validate                      # needs kubectl, docker, python3 + PyYAML
tests/k8s/kind-e2e.sh docker-wine:local       # needs kind and a native Linux Docker host
```

`kind-e2e.sh` deploys to a kind cluster under Pod Security "restricted" and connects over RDP; it does not work under Docker Desktop's VM networking.

## License

[MIT](LICENSE)
