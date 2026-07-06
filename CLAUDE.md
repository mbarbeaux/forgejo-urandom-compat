# CLAUDE.md

Context for Claude (or any future revival of this repository).

## What this repository does

A single `Dockerfile` that rebuilds the official
`codeberg.org/forgejo/forgejo:15-rootless` image, replacing Alpine's `git`
binary with a version recompiled from source, to make it usable on a
Linux kernel older than 3.17 (typically Synology NAS devices, many models
of which still run kernel 3.10 even under recent DSM — DSM 7.2, 7.3...).

Do not confuse this with a rework of Forgejo itself: only the Git binary
is replaced, everything else in the image (Forgejo/Gitea, its
configuration, its volumes) is strictly identical to the official image.

## Commit message convention

All commits in this repository must follow [Conventional Commits](https://www.conventionalcommits.org/)
(`type(scope): description`, e.g. `fix(docker): ...`, `docs(readme): ...`,
`ci(workflow): ...`). This applies to every commit, including ones authored
by Claude.

## The original problem (symptom)

```
CreatePost, CreateRepository(git update-server-info): exit status 1
error: unable to get random bytes for temporary file: Function not implemented
error: unable to update info/refs: Function not implemented
error: unable to update objects/info/packs: Function not implemented
```

This error appears as soon as you try to create a repository (or run any
`git add`/`git commit`/`git init`) in the Forgejo UI, on a host whose
`uname -r` reports a kernel < 3.17 (e.g. `3.10.108` on Synology).

## Root cause (full diagnosis)

1. Since **Git 2.36** (patch by brian m. carlson, November 2021, merged
   in early 2022), Git uses a `csprng_bytes()` function (in `wrapper.c`)
   to generate temporary filenames in a cryptographically secure way.
2. On Linux, if the code was compiled with `HAVE_GETRANDOM` defined, this
   function calls the **`getrandom(2)`** syscall **directly**
   — available only since kernel **3.17** — **with no fallback**
   to the old `/dev/urandom` method if the call fails.
3. **The main trap** (the one that wasted the most time): Git's
   `config.mak.uname` file **automatically forces**
   `CSPRNG_METHOD = getrandom` for any system detected as `Linux`,
   **regardless** of whether we define that variable ourselves. Simply
   not mentioning it at all is NOT enough — it must be explicitly
   overridden via the `make` command line (`CSPRNG_METHOD=` empty),
   which takes priority over any in-Makefile assignment.
4. The Git packages precompiled by **Alpine Linux** (used in the official
   Forgejo Docker image, based on Alpine) are built with this default
   behavior — hence the systematic bug on any official Forgejo/Gitea
   image running on an old kernel.
5. On the Synology NAS tested, the **native Git** client (installed via
   the Synology Package Center) worked fine — because it was compiled
   **without** the `getrandom` option enabled (so with a native fallback
   to `/dev/urandom`). So this is not a matter of Git version (the native
   one was 2.52.0, newer than Alpine's), but purely a matter of
   **compile-time option**.

## Approaches explored and ruled out (to avoid retrying them)

- **Injecting the NAS's native Git into the container** (bind-mount):
  ruled out. The native Synology binary is dynamically linked against
  **glibc** (`interpreter /lib64/ld-linux-x86-64.so.2`), while the
  Forgejo container runs on **Alpine/musl**. Total binary incompatibility
  (missing ELF interpreter, different shared libraries).
- **Updating DSM to the latest major version**: ruled out. On Synology,
  the kernel version is tied to the **hardware platform** (the NAS
  model/its CPU), not the DSM version. A NAS can remain stuck on kernel
  3.10 even on DSM 7.3, the latest fully supported version at the time of
  writing.

## Chosen solution: recompile Git inside the official image itself

See `Dockerfile` — a 3-stage approach:

1. `FROM codeberg.org/forgejo/forgejo:15-rootless AS forgejo-original`:
   reference image, used twice (as the build base AND the final base),
   to guarantee zero environment drift (same Alpine/musl version as the
   image being modified).
2. `git-builder` stage, **`FROM forgejo-original`** (not a separate
   Alpine image): we directly query the `git --version` already
   installed in that image to know the exact version to recompile,
   without hardcoding anything. We download the matching GitHub tag,
   recompile with the options below, and verify the result.
3. Final image: we start again from the untouched `forgejo-original`,
   remove the apk `git` package (`apk del`, to prevent a future
   `apk upgrade` from reintroducing the broken Git), and copy the
   compiled files in its place.

### Critical compile options (`make` invocation)

```
make -j"$(nproc)" \
    LDFLAGS="-static -Wl,--allow-multiple-definition" \
    CURL_LIBCURL="$(pkg-config --static --libs libcurl)" \
    CSPRNG_METHOD= \
    NO_GETTEXT=1 NO_PERL=1 NO_TCLTK=1 NO_GITWEB=1 \
    DESTDIR=/build install
```

- **`CSPRNG_METHOD=`** (empty, explicit): the central fix. Forces the
  fallback to `/dev/urandom` instead of `getrandom(2)` (see root cause
  point 3 above).
- **`LDFLAGS="-static"`**: static linking requested, for a fully
  self-contained binary (no dependency on `musl`/`libcurl`/etc. in the
  final image). The result is reported by `file` as `static-pie linked`
  (not plain `statically linked`) — this is normal and still a static
  binary, just with PIE relocation.
- **`-Wl,--allow-multiple-definition`**: needed because `libidn2`
  (a transitive static dependency of `curl`) bundles an `error()`
  function via `gnulib`, which collides by name with the `error()`
  function in Git's own `usage.c`. Without this flag, linking fails with
  `multiple definition of 'error'`.
- **`CURL_LIBCURL="$(pkg-config --static --libs libcurl)"`**: works
  around Git's internal detection (`CURL_STATIC=YesPlease` → `curl-config
  --static-libs`), which turned out to be **incomplete** on the Alpine
  version tested (it omitted OpenSSL, nghttp2, c-ares, libpsl, brotli,
  zstd from the link line). `pkg-config --static` reads curl's standard
  `Libs.private` `.pc` field, and proved reliable for getting the full
  dependency chain, in the right order.
- **`NO_GETTEXT` / `NO_PERL` / `NO_TCLTK` / `NO_GITWEB`**: aligned with
  what Alpine's official `git` package already doesn't bundle (its
  runtime dependencies list neither perl nor gettext), to stay consistent
  and limit the build surface.

### Alpine packages needed for static linking

On recent Alpine, static libraries (`.a` files) are split out of the
usual `-dev` packages into dedicated `-static` packages. Full list used
(determined through successive iterations, resolving each
`cannot find -lXXX` one by one):

```
build-base autoconf pkgconf
curl-dev curl-static
expat-dev expat-static
pcre2-dev pcre2-static
zlib-dev zlib-static
openssl-dev openssl-libs-static
nghttp2-static
brotli-static
zstd-static
libpsl-static
libidn2-static
libunistring-static
```

### Two automatic checks built into the build

The `Dockerfile` deliberately fails the build (`exit 1`) if either of
these two conditions isn't met — so **a successful build is itself proof
that the fix is active**:

1. `strings /build/usr/bin/git | grep "^/dev/urandom$"` must find the
   string — confirms that the fallback branch (not `getrandom()`) was
   indeed compiled in. Verified by directly reading the `wrapper.c`
   source: this literal string only appears in the final `#else` branch
   of `csprng_bytes()`.
2. `file /build/usr/bin/git` must contain `statically linked` **or**
   `static-pie linked`.

### Runtime constraint: `USER root` / `USER 1000`

Forgejo's `rootless` image runs by default as the non-root user UID 1000.
`apk` needs root to write to `/var/lib/apk` and `/var/cache/apk` — hence
the `USER root` before each `apk` block, and a final `USER 1000` to avoid
changing the image's runtime behavior (security, consistency with the
user's existing `docker-compose.yml` configuration).

## Validated state

Build tested and working on an **aarch64** (ARM) architecture, with
Git 2.52.0, on a `codeberg.org/forgejo/forgejo:15-rootless` image based
on Alpine 3.23. **Tested in production on a Synology DSM 7.2
(kernel 3.10.108)**: repository creation works.

## CI/CD (GitHub Actions)

`.github/workflows/docker-build.yml` builds and publishes the image to
GitHub Container Registry (`ghcr.io`), matching the official image's
architectures — `amd64`, `arm64`, `arm/v6` (checked via
`docker manifest inspect codeberg.org/forgejo/forgejo:15-rootless`) —
using QEMU emulation on GitHub's amd64-only hosted runners.

Triggers: push to `main` touching the `Dockerfile` or the workflow
itself, a weekly schedule (Mondays 03:00 UTC, to absorb upstream
`15-rootless` updates automatically), and manual `workflow_dispatch`.

Important operational note: the GHCR package created by the workflow is
**private by default** on first push, even though the repository is
public — it must be switched to "Public" once, manually, in the
package's settings page, otherwise `docker pull` will require
authentication.

## Points of attention for a future revival

- If Alpine ships an urgent Git security fix without changing the version
  number (`git --version`), our build (based on the official GitHub tag)
  won't include it automatically. Watch upstream Git security
  announcements in case of a critical CVE.
- If the `-static` package names change in a future major Alpine version
  (which already happened once during development), the build will fail
  at the `apk add` step or at the link step with `cannot find -lXXX`
  errors — in that case, identify the missing library symbol by symbol
  (see method above).
- If Forgejo ever changes its container base (e.g. drops Alpine), all of
  this Git compilation logic needs to be revisited accordingly.
