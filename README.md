# forgejo-urandom-compat

[![Build and publish Docker image](https://github.com/mbarbeaux/forgejo-urandom-compat/actions/workflows/docker-build.yml/badge.svg?branch=main)](https://github.com/mbarbeaux/forgejo-urandom-compat/actions/workflows/docker-build.yml)

## Forgejo 15-rootless — Synology-compatible build (old kernel)

This repository contains a `Dockerfile` that rebuilds the official
[`codeberg.org/forgejo/forgejo:15-rootless`](https://codeberg.org/forgejo/forgejo)
image with a **recompiled Git binary**, to make it compatible with Synology
NAS devices (and more generally any system running a **Linux kernel older
than 3.17**, such as the 3.10 kernel used by many Synology models even
under recent DSM 7.x/7.3).

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

```bash
./build.sh
```

This produces an image named `forgejo:15-rootless-synology-compatible`.

Then update your `docker-compose.yml`:

```yaml
services:
  forgejo:
    image: forgejo:15-rootless-synology-compatible  # instead of codeberg.org/forgejo/forgejo:15-rootless
    # ... rest of your configuration unchanged
```

Then recreate the container:

```bash
docker compose up -d
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

It triggers:

- on every push to `main` that modifies the `Dockerfile` (or the workflow
  itself);
- weekly (every Monday), to automatically recompile and track updates to
  the official `15-rootless` image (Alpine/Git security patches) with no
  manual intervention;
- manually, via the repository's *Actions* tab (`workflow_dispatch`).

**Making the package public**: the first time the workflow pushes the
image, the resulting GHCR package is **private by default**, even if the
repository is public. So, once, you need to go to
`https://github.com/users/<owner>/packages/container/forgejo-urandom-compat/settings`
and switch its visibility to *Public* to allow an unauthenticated
`docker pull`.

Once public:

```bash
docker pull ghcr.io/<owner>/forgejo-urandom-compat:latest
```

## Maintenance

- **Updating Forgejo**: just change the tag on the
  `FROM codeberg.org/forgejo/forgejo:15-rootless` line in the `Dockerfile`,
  then rerun `./build.sh`. The Git version will automatically be
  realigned with the one bundled in the new official image.
- **Verifying after a build**: the build deliberately fails (`exit 1`) if
  the compiled binary doesn't use `/dev/urandom` — so a `./build.sh` that
  finishes without error is itself a guarantee that the fix is active.
- **Known limitation**: if Alpine ships an urgent Git security fix
  without changing the version number reported by `git --version`, our
  build — recompiled from the official GitHub tag — won't include it
  automatically. Watch for upstream Git security advisories in case of a
  critical CVE.

## Origin

This `Dockerfile` was put together with the assistance of Claude
(Anthropic), starting from an error encountered on a Synology DSM 7.2
(kernel 3.10.108).
