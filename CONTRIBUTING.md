# Contributing to docker-wine

Thank you for taking an interest in docker-wine and wanting to contribute.

## How you can help

* Report bugs, issues or general feedback by opening a [New Issue](https://github.com/kamphaus/docker-wine/issues/new/choose)
* Request features and enhancements
* Submit a pull request

## Pull requests

* Keep the image general: do not add changes for niche use cases that will not benefit others.
* Everything is pinned (base image digest, Wine and winetricks versions, GitHub Actions by commit SHA) and kept current by Renovate. Do not bypass the pins; see the README for how derived images and the shared Renovate preset work.
* All shell scripts should pass `shellcheck` without `# shellcheck disable=...` comments.
* Run the tests before opening a PR (see "Testing" in the [README](README.md#testing)): `./build -q && tests/run docker-wine:local && tests/manifests/validate`. CI runs the same checks, plus an end-to-end test on kind for pull requests.
* Conventional Commits are preferred, but not required.

## Deployment of images

CI (`.github/workflows/ci.yml`) builds, tests and scans the image on every push and pull request. Pushes to `master` publish the image to GHCR, with an SBOM, a provenance attestation and a cosign signature. Details on usage, pinning and updates are in the [README](README.md).
