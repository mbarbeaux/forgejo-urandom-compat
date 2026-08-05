# forgejo-urandom-compat

[![Build and publish Docker image](https://github.com/mbarbeaux/forgejo-urandom-compat/actions/workflows/docker-build.yml/badge.svg?branch=main)](https://github.com/mbarbeaux/forgejo-urandom-compat/actions/workflows/docker-build.yml)

## Forgejo rootless (>= 15) — Synology-compatible build (old kernel)

This repository contains a `Dockerfile` that rebuilds the official
[`codeberg.org/forgejo/forgejo`](https://codeberg.org/forgejo/forgejo)
`<major>.<minor>.<patch>-rootless` images (every 15.x.y release and any
newer major published upstream) with a **recompiled Git binary**, to make
them compatible with Synology NAS devices (and more generally any system
running a **Linux kernel older than 3.17**, such as the 3.10 kernel used
by many Synology models even under recent DSM 7.x/7.3).

## The problem being solved

On these systems, creating a repository (or any `git add`/`git commit`)
fails with an error like:

```
CreatePost, CreateRepository(git update-server-info): exit status 1
error: unable to get random bytes for temporary file: Function not implemented
error: unable to update info/refs: Function not implemented
```

**Cause:** since Git 2.36, temporary filename generation uses the Linux
`getrandom(2)` syscall — available only since kernel 3.17. The Git
packages shipped by Alpine Linux (used in the official Forgejo image) are
compiled to use this call **with no fallback** to the older method
(`/dev/urandom`), which breaks Git on older kernels — kernels that many
Synology NAS devices still run, including on recently sold models.

**Solution:** this `Dockerfile` recompiles Git from source, with the
options needed to force the use of `/dev/urandom` (compatible with any
kernel), and links the binary **statically** for extra robustness and
portability.

## Usage

Pull the pre-built image from GitHub Container Registry. One image is
published per upstream Forgejo release (e.g. `15.0.6-rootless`,
`16.0.2-rootless`...). Two kinds of moving tags are also kept up to date:
`latest` always points to the most recent release overall, and
`<major>-rootless` (e.g. `15-rootless`, `16-rootless`...) always points to
the most recent release within that major line:

```bash
docker pull ghcr.io/mbarbeaux/forgejo-urandom-compat:latest
# or follow a specific Forgejo major (auto-updates on new patches):
docker pull ghcr.io/mbarbeaux/forgejo-urandom-compat:15-rootless
# or pin an exact Forgejo release:
docker pull ghcr.io/mbarbeaux/forgejo-urandom-compat:15.0.6-rootless
```

Then update your `docker-compose.yml`:

```yaml
services:
  forgejo:
    image: ghcr.io/mbarbeaux/forgejo-urandom-compat:15.0.6-rootless  # instead of codeberg.org/forgejo/forgejo:15.0.6-rootless
    # ... rest of your configuration unchanged
```

Then recreate the container:

```bash
docker compose up -d
```

Alternatively, you can build a given version yourself locally, via the
`FORGEJO_TAG` build argument (defaults to `15-rootless`, the floating tag
for the latest 15.x.y release):

```bash
docker build -t forgejo-urandom-compat --build-arg FORGEJO_TAG=16.0.2-rootless .
```

## How it works

The `Dockerfile`:

1. Starts from the official Forgejo image as-is (`forgejo-original`).
2. In a build stage (`git-builder`), **based on that same image**,
   installs the build tools, then:
   - automatically detects the Git version already installed
     (`git --version`), to recompile exactly the same version — with
     nothing to type manually;
   - downloads the matching sources from GitHub;
   - recompiles them with `CSPRNG_METHOD=` (empty), to force the fallback
     to `/dev/urandom` instead of `getrandom()`;
   - links the result statically (`LDFLAGS="-static"`), for a fully
     self-contained binary, with no dependency on `musl`/`libcurl`/etc.;
   - automatically verifies, via two checks, that the resulting binary is
     indeed static **and** does use `/dev/urandom` (the build explicitly
     fails otherwise).
3. In the final image, removes Alpine's `git` package (to prevent a future
   `apk upgrade` from overwriting it) and copies our compiled binary in
   its place.

See the comments in the `Dockerfile` for the details of each technical
choice (library link order, symbol conflict with `libidn2`, etc.) — see
also `CLAUDE.md` for the full history of the debugging process.

## Pre-built image (GitHub Actions CI)

This repository includes a GitHub Actions workflow
(`.github/workflows/docker-build.yml`) that automatically builds and
publishes the image to **GitHub Container Registry**, for the same
architectures as the official image (`amd64`, `arm64`, `arm/v6` — verified
via `docker manifest inspect codeberg.org/forgejo/forgejo:15-rootless`),
using QEMU emulation on GitHub's hosted (amd64-only) runners.

The workflow first **discovers** every exact Forgejo rootless release
published upstream at `codeberg.org/forgejo/forgejo` (major >= 15, across
every major line), then builds one image **per release not already
published** on `ghcr.io` — an already-built release is never rebuilt,
since its upstream tag is immutable and rebuilding it would just waste CI
time. The most recent release overall is tagged `latest`, and each major
line's most recent release is additionally tagged `<major>-rootless`
(e.g. `15-rootless`, `16-rootless`...). This means both a brand new major
(e.g. `17.0.0-rootless`) and a new patch on an existing major (e.g.
`16.0.3-rootless`) are picked up, built, and tagged automatically, with no
manual change to this repository. Each release builds in its own job (all
three architectures together), so releases build in parallel.

It triggers:

- on every push to `main` that modifies the `Dockerfile` (or the workflow
  itself);
- daily (03:00 UTC), to detect and build any new Forgejo release
  published in the meantime, across every supported major;
- manually, via the repository's *Actions* tab (`workflow_dispatch`), with
  an optional `forgejo_version` input to force a rebuild of one exact
  release (e.g. `16.0.2-rootless`) even if it was already published.

**Making the package public**: the first time the workflow pushes the
image, the resulting GHCR package is **private by default**, even if the
repository is public. So, once, you need to go to
`https://github.com/users/mbarbeaux/packages/container/forgejo-urandom-compat/settings`
and switch its visibility to *Public* to allow an unauthenticated
`docker pull` (see the [Usage](#usage) section above).

## Maintenance

- **Updating Forgejo**: nothing to do — the CI workflow discovers every
  upstream release on each run and builds whatever isn't published yet.
  For a local, one-off build of a specific release, pass
  `--build-arg FORGEJO_TAG=<major>.<minor>.<patch>-rootless` to
  `docker build` (see [Usage](#usage) above). The Git version is always
  realigned automatically with the one bundled in the corresponding
  official image.
- **Verifying after a build**: the build deliberately fails (`exit 1`) if
  the compiled binary doesn't use `/dev/urandom` — so a
  `docker build` that finishes without error is itself a guarantee that
  the fix is active.
- **Known limitation**: because each release is built once and never
  rebuilt (its upstream tag is immutable), an Alpine/Git security fix
  shipped by upstream *without* a new Forgejo release tag won't reach an
  already-published image automatically. Use the manual
  `workflow_dispatch` (`forgejo_version` input) to force a rebuild of an
  affected release if that ever happens, and watch upstream Git security
  advisories in case of a critical CVE.

## Origin

This `Dockerfile` was put together with the assistance of Claude
(Anthropic), starting from an error encountered on a Synology DSM 7.2
(kernel 3.10.108).

## License

This project is licensed under the [MIT License](LICENSE).
