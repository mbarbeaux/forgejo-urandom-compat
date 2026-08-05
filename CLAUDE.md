# CLAUDE.md

Context for Claude (or any future revival of this repository).

## What this repository does

A single `Dockerfile` that rebuilds the official
`codeberg.org/forgejo/forgejo:<major>.<minor>.<patch>-rootless` images
(every 15.x.y release and any newer major), replacing Alpine's `git`
binary with a statically-linked, `/dev/urandom`-patched build, to make it
usable on a Linux kernel older than 3.17 (typically Synology NAS devices,
many models of which still run kernel 3.10 even under recent DSM —
DSM 7.2, 7.3...). The base tag is selected via the `FORGEJO_TAG` build arg
(default `15-rootless`, the floating tag for the latest 15.x.y release);
the CI workflow discovers every upstream release automatically and builds
one image per release not yet published (see
[CI/CD](#cicd-github-actions) below).

**This repository no longer compiles Git itself.** It fetches a pre-built
binary from [git-urandom-compat](https://github.com/mbarbeaux/git-urandom-compat)
instead — see [Chosen solution](#chosen-solution-fetch-a-pre-built-git-instead-of-recompiling-it)
below for why, and that repository's own `CLAUDE.md` for the actual
compile recipe (options, Alpine packages, verification checks) — it's
unchanged from what used to live in this repository's `Dockerfile`,
just relocated.

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

## Chosen solution: fetch a pre-built Git instead of recompiling it

See `Dockerfile` — a 2-stage approach:

1. `FROM codeberg.org/forgejo/forgejo:${FORGEJO_TAG} AS forgejo-original`
   (`FORGEJO_TAG` defaults to `15-rootless`): reference image, used twice
   (as the fetch base AND the final base), to guarantee zero environment
   drift (same Alpine/musl version as the image being modified).
2. `git-fetcher` stage, **`FROM forgejo-original`** (not a separate
   Alpine image): directly queries the `git --version` already installed
   in that image, exactly like the old design used to, to know exactly
   which Git version to fetch — then, instead of downloading the GitHub
   source tag and compiling it, uses `skopeo copy` to pull the matching
   release from `ghcr.io/mbarbeaux/git-urandom-compat` and extracts it
   (see "Why `skopeo copy` in a `RUN`, not `FROM`" below), verifying the
   result the same way the old compile step did.
3. Final image: starts again from the untouched `forgejo-original`,
   removes the apk `git` package (`apk del`, to prevent a future
   `apk upgrade` from reintroducing the broken Git), and copies the
   fetched files in its place.

This was **originally a single self-contained `git-builder` stage that
recompiled Git from source** (the actual `make`/`CSPRNG_METHOD=`/static
-link recipe, the Alpine `-static` package list, and the two verification
checks are documented in `git-urandom-compat`'s own `CLAUDE.md` now, byte
-for-byte the same as what used to be here). That approach was split out
into its own repository after noticing that 10 consecutive Forgejo
releases (15.0.0 through 16.0.2) all embedded the exact same Git version
(2.52.0) — recompiling it independently for every one of them, each
taking roughly an hour due to QEMU cross-compilation, was pure redundant
CI time. See `git-urandom-compat/CLAUDE.md` for the full reasoning.

### Why `skopeo copy` in a `RUN`, not `FROM`

The natural-looking design would be a plain multi-stage
`FROM ghcr.io/mbarbeaux/git-urandom-compat:${GIT_VERSION} AS git-source`
followed by `COPY --from=git-source`. This doesn't work here: a
Dockerfile's `FROM` target has to be resolved before the build starts, so
it can't be parameterized by a value (the detected Git version) computed
by an earlier stage's `RUN` output within the SAME build. The only way to
use a `FROM`-based design would be to detect the Git version OUTSIDE the
Dockerfile (e.g. a CI step running `docker run ... git --version` on the
target Forgejo image) and pass it in as a build-arg -- this was tried
first and reverted, because it can only check ONE platform (the CI
runner is amd64-only) and then reuses that single detected version as the
build-arg for EVERY platform in the multi-arch build. If Forgejo's
per-architecture images were ever NOT built from byte-identical Alpine
package snapshots (not guaranteed, even if true in practice today), that
single amd64-detected version would silently get baked into the arm64
and arm/v6 builds too, even if those platforms actually bundled a
different Git version.

`skopeo copy` inside a `RUN` step avoids this entirely: it runs INSIDE
each platform's own copy of the `git-fetcher` stage (under QEMU emulation
for arm64/arm-v6, same as the old compile step did), so `git --version`
there reads THAT platform's actual bundled Git version, and `skopeo`
itself -- installed via `apk`, so it's the correct native binary for
whatever platform is currently building -- automatically resolves
`git-urandom-compat`'s own multi-arch tag to the matching platform when
fetching. This mirrors exactly how `apk add` itself already resolves the
right per-architecture packages under emulation elsewhere in this
Dockerfile; extending that same trust to `skopeo` was a deliberate
choice, not an oversight.

Mechanically: `skopeo copy docker://<ref> dir:/tmp/git-oci` writes an OCI
image layout (a `manifest.json` plus one file per blob) rather than
running or exporting the image directly (skopeo isn't a container
runtime, it can't "run" anything). The image is `FROM scratch` with
exactly 3 `COPY` layers (`/bin/git*`, `/libexec/git-core/`,
`/share/git-core/`), each a `tar+gzip` blob — so extracting every layer
listed in `manifest.json`'s `.layers[]`, in order, into the same
destination directory reconstructs the exact rootfs Docker itself would
have produced via `COPY --from=`. Verified locally end-to-end, including
under `riscv64` QEMU emulation, before ever relying on it in CI.

### Runtime constraint: `USER root` / `USER 1000`

Forgejo's `rootless` image runs by default as the non-root user UID 1000.
`apk` needs root to write to `/var/lib/apk` and `/var/cache/apk` — hence
the `USER root` before each `apk` block, and a final `USER 1000` to avoid
changing the image's runtime behavior (security, consistency with the
user's existing `docker-compose.yml` configuration).

## Validated state

Original recompile-in-place design: build tested and working on an
**aarch64** (ARM) architecture, with Git 2.52.0, on a
`codeberg.org/forgejo/forgejo:15-rootless` image based on Alpine 3.23.
**Tested in production on a Synology DSM 7.2 (kernel 3.10.108)**:
repository creation works.

Current `skopeo`-fetch design: full end-to-end `docker build` (both
stages, urandom + static checks, `git init`/`git commit`) verified
locally for `linux/amd64`. The per-platform `skopeo`-under-emulation
extraction mechanism itself was verified separately, under `riscv64`
QEMU emulation, while building `git-urandom-compat`. The `arm64`/`arm/v6`
legs specifically, inside THIS repository's own multi-platform build,
get their first real validation from the CI run that follows this
change -- not yet independently re-tested locally before that.

## CI/CD (GitHub Actions)

`.github/workflows/docker-build.yml` has two jobs:

1. `discover`: uses `skopeo list-tags` against
   `codeberg.org/forgejo/forgejo` to enumerate every published tag, keeps
   the exact releases matching `^[0-9]+\.[0-9]+\.[0-9]+-rootless$` with
   major >= `MIN_MAJOR_VERSION` (currently 15) across every major line
   (this is what makes a brand new major, e.g. `17.0.0-rootless`, or a new
   patch on an existing major, e.g. `16.0.3-rootless`, get picked up with
   no manual change to this repository). It then logs into `ghcr.io`
   (read-only, via `GITHUB_TOKEN`) and lists this repository's already
   -published tags, to compute the SET DIFFERENCE: upstream releases minus
   already-built releases. Only that difference is exposed as the build
   matrix (`versions` output) — an already-built release is never
   rebuilt, since its upstream tag is immutable (no point burning CI time
   on it). `latest` (separate output) is always computed from the FULL
   upstream release list, regardless of what's actually being built this
   run, even when `workflow_dispatch.forgejo_version` restricts the build
   to a single forced release — so a manual rebuild of an old release
   never mislabels it `latest`, and skipping an already-built release
   never leaves `latest` stale (it was already set correctly by whichever
   run originally built it). `discover` also computes `major_latest`: a
   JSON object mapping each major to its highest patch found (e.g.
   `{"15":"15.0.6-rootless","16":"16.0.2-rootless"}`), built with a single
   `awk` pass that overwrites `lat[major]` while walking the
   already-sorted-ascending `upstream_versions` list — no numeric
   comparison needed, the last line seen per major is always its highest.
   It also computes `source_digests`: a JSON object mapping EVERY upstream
   release to its current manifest digest, via `skopeo inspect --raw |
   sha256sum` (not `skopeo inspect`'s own `.Digest` field, which resolves
   to the runner's own platform's child manifest instead of the stable
   index digest that changes when ANY platform's content changes). This
   feeds two things: the `FORGEJO_SOURCE_DIGEST` build-arg for whatever
   gets built this run, and a DRIFT CHECK against already-built releases —
   for each one, `discover` reads back its own
   `org.forgejo-urandom-compat.source-digest` label (see Dockerfile) via
   `skopeo inspect` and compares it to upstream's current digest; a
   mismatch adds that release back into the build matrix even though its
   version string was already published (this is how an Alpine/Git
   security backport re-pushed under the same Forgejo tag still gets
   picked up). A MISSING label (a release built before this label
   existed) is deliberately NOT treated as drift: the alternative would
   have forced a one-off rebuild of every already-published release the
   first time this ran, just to backfill the label, which was judged not
   worth it -- those specific releases simply aren't drift-protected until
   manually rebuilt (`workflow_dispatch`) or naturally superseded.
   `versions` ends up as `missing ∪ drifted`, deduped.
2. `build`: matrix job (one job per release still needing a build; skipped
   entirely via `if: needs.discover.outputs.versions != '[]'` when there's
   nothing new) that builds and pushes the image to GitHub Container
   Registry (`ghcr.io`), matching the official image's architectures —
   `amd64`, `arm64`, `arm/v6` (checked via `docker manifest inspect
   codeberg.org/forgejo/forgejo:15-rootless`) — using QEMU emulation on
   GitHub's amd64-only hosted runners, all three architectures within the
   same job for that one release. Each image is tagged with its exact
   release string (e.g. `16.0.2-rootless`). A `Determine major-line tag
   and source digest` shell step extracts the major from
   `matrix.forgejo_version` (bash `${VERSION%%.*}`, since GitHub Actions
   expressions have no string-split function), looks it up in
   `major_latest`'s JSON via `jq` to decide the floating
   `<major>-rootless` tag (e.g. `16.0.2-rootless` also gets
   `16-rootless`), and looks up this version's entry in `source_digests`
   to pass as the `FORGEJO_SOURCE_DIGEST` build-arg, baked into the image's
   label by the Dockerfile. The release matching `discover`'s `latest`
   output additionally gets `latest`.

Triggers: push to `main` touching the `Dockerfile` or the workflow
itself, a daily schedule (03:00 UTC, to detect and build any new Forgejo
release within a day, across every supported major -- cheap on days with
nothing new, since `discover` just skips the `build` job), and manual
`workflow_dispatch` (with an optional `forgejo_version` input to force a
rebuild of one exact release even if already published).

Important operational note: the GHCR package created by the workflow is
**private by default** on first push, even though the repository is
public — it must be switched to "Public" once, manually, in the
package's settings page, otherwise `docker pull` will require
authentication.

## Points of attention for a future revival

- Alpine/Git security fixes shipped by upstream WITHOUT a new Forgejo
  release tag are handled automatically as long as upstream actually
  re-pushes the affected release's image (the source-digest drift check
  in `discover` picks it up, see [CI/CD](#cicd-github-actions) above). The
  remaining gap is narrower than it sounds: (1) releases built before the
  `org.forgejo-urandom-compat.source-digest` label existed aren't
  drift-checked (missing label = assumed up to date) -- force a rebuild
  via `workflow_dispatch` for one of those specific releases if it turns
  out to need one; (2) if upstream never re-pushes the affected tag at
  all, there's genuinely nothing to detect or fix on our side -- our image
  is exactly as stale as upstream's own, and watching upstream Git
  security advisories is the only recourse for a critical CVE in that
  case.
- The `-static` package / static-link fragility documented above (Alpine
  renaming `-static` packages, curl's incomplete static-libs detection,
  etc.) no longer applies to THIS repository at all -- that risk now lives
  entirely in `git-urandom-compat`, since this repository doesn't compile
  anything anymore. Check there if a Git version fails to build.
- This repository now has a HARD runtime dependency on
  `ghcr.io/mbarbeaux/git-urandom-compat` being public and having already
  published whatever Git version the Forgejo release being built bundles
  -- if that version isn't there yet, `skopeo copy` in the `git-fetcher`
  stage fails the build outright, with no fallback to compiling locally.
  This is why `git-urandom-compat`'s daily schedule runs 3 hours ahead of
  this repository's own (see [CI/CD](#cicd-github-actions) below); if that
  margin ever turns out to be too tight, or if `git-urandom-compat`'s own
  package visibility ever reverts to private, this repository's builds
  will fail with a clear `skopeo`/`403`/`manifest unknown` error at the
  `git-fetcher` stage, not a subtle miscompile.
- If Forgejo ever changes its container base (e.g. drops Alpine), the
  `git-fetcher` stage's `apk add skopeo jq` and the final stage's
  `apk del git` both assume Alpine/`apk` are present -- would need
  revisiting accordingly (as would `git-urandom-compat`, on its own
  side, for the actual Git build).
- The `discover` job relies on `codeberg.org/forgejo/forgejo` staying a
  publicly readable container repository (anonymous `skopeo list-tags`)
  and on upstream keeping the `<major>.<minor>.<patch>-rootless` exact tag
  naming scheme. If either changes, the discovery step needs to be
  adjusted (or the tag regex updated) before it can find new releases
  again.
- `MIN_MAJOR_VERSION` (currently 15) is a workflow-level env var in
  `docker-build.yml` — bump it there if support for older majors is ever
  dropped.
- The already-built/already-published diff in `discover` trusts
  `ghcr.io`'s tag list as the source of truth for "what's been built" —
  there is no separate state file to go stale or drift. Manually deleting
  a version tag from the GHCR package would make `discover` consider it
  missing again and rebuild it on the next run.
