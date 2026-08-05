# syntax=docker/dockerfile:1

# ==============================================================================
# Reference: the official Forgejo image, used twice below
# (once as the build base, once as the final base).
# FORGEJO_TAG selects which upstream rootless tag to rebuild -- a floating
# major tag (e.g. 15-rootless) or an exact release (e.g. 16.0.2-rootless).
# The CI workflow discovers every upstream release automatically and
# builds one image per exact release not yet published (see
# .github/workflows/docker-build.yml); for a local one-off build, override
# it with `--build-arg FORGEJO_TAG=16.0.2-rootless`.
# ==============================================================================
ARG FORGEJO_TAG=15-rootless
FROM codeberg.org/forgejo/forgejo:${FORGEJO_TAG} AS forgejo-original

# ==============================================================================
# Git source: a statically-linked, /dev/urandom-patched Git, pre-built by
# github.com/mbarbeaux/git-urandom-compat instead of being recompiled here.
#
# This stage detects the Git version bundled in forgejo-original with the
# same `git --version` trick the old recompile-in-place design used, and
# for the SAME reason: this build produces one image per platform
# (amd64/arm64/arm-v6) in a single multi-arch invocation, each running its
# own copy of this stage under QEMU emulation where relevant, so each
# platform reads its OWN forgejo-original's bundled Git version
# independently. This matters because it can't be assumed that Forgejo's
# amd64 and arm64 images were built from identical Alpine package
# snapshots at the exact same instant -- detecting per-platform, from
# inside each platform's own build, is the only way to guarantee the Git
# version matches THAT platform's Forgejo image, not just whichever
# platform happened to be checked from outside the build.
#
# A Dockerfile FROM target can't be parameterized by a value computed
# during the build (it has to be known before the build starts), which
# rules out `FROM ghcr.io/.../git-urandom-compat:${GIT_VERSION}` for a
# per-platform-detected GIT_VERSION. Instead, `skopeo copy` fetches the
# matching image directly inside this RUN step: skopeo itself is
# installed via apk, so under emulation it's the correct native binary
# for whatever platform this stage is currently building, and resolves
# git-urandom-compat's own multi-arch tag to the matching platform
# automatically -- the same mechanism that makes `apk add` itself
# resolve the right per-platform packages during a QEMU-emulated build.
# ==============================================================================
FROM forgejo-original AS git-fetcher

USER root

RUN apk add --no-cache skopeo jq file

RUN GIT_VERSION="$(git --version | awk '{print $3}')" \
    && echo "Git version bundled in this Forgejo image: ${GIT_VERSION}" \
    && mkdir -p /tmp/git-oci /build \
    && skopeo copy "docker://ghcr.io/mbarbeaux/git-urandom-compat:${GIT_VERSION}" dir:/tmp/git-oci \
    && for layer in $(jq -r '.layers[].digest' /tmp/git-oci/manifest.json | sed 's/^sha256://'); do \
           tar -xf "/tmp/git-oci/${layer}" -C /build; \
       done \
    && rm -rf /tmp/git-oci

# Sanity check: git-urandom-compat already verifies its own build (static
# link + /dev/urandom fallback) before ever publishing it, but re-checking
# the fetched artifact here is essentially free and catches an
# integration mistake on THIS side (wrong version resolved, wrong tag)
# rather than trusting it blindly. `file`/`strings` are only installed in
# this throwaway build stage, not the final runtime image.
RUN if strings /build/bin/git | grep -q "^/dev/urandom$"; then \
        echo "OK: /dev/urandom fallback found in the fetched binary"; \
    else \
        echo "ERROR: /dev/urandom string not found -- getrandom() may still be in use!" && exit 1; \
    fi

RUN /build/bin/git --version \
    && (file /build/bin/git | grep -qE "statically linked|static-pie linked" \
        && echo "OK: static binary confirmed" \
        || (echo "ERROR: the binary does not appear to be static!" && file /build/bin/git && exit 1))

# ==============================================================================
# Final image: start again from the untouched official image, remove the
# apk git package (so a future apk upgrade can't overwrite it), then copy
# the pre-built statically-linked binary in its place.
# ==============================================================================
FROM forgejo-original

# The rootless image runs as a non-root user (UID 1000) by default.
# apk needs root privileges to write to /var/lib/apk and /var/cache/apk.
USER root

RUN apk del --no-cache git \
    && rm -rf /var/cache/apk/*

COPY --from=git-fetcher /build/bin/git* /usr/bin/
COPY --from=git-fetcher /build/libexec/git-core/ /usr/libexec/git-core/
COPY --from=git-fetcher /build/share/git-core/ /usr/share/git-core/

# Confirms the copy actually landed a working binary at the expected path
# (git-fetcher already verified the fetched artifact itself is static and
# /dev/urandom-patched -- `file`/`strings` aren't installed in this final
# runtime image, so this step deliberately stays limited to what's
# available here).
RUN /usr/bin/git --version

# Records the upstream Forgejo manifest digest this image was built from
# (FORGEJO_TAG alone isn't enough to know if that upstream tag was
# silently re-pushed since our last build -- see
# .github/workflows/docker-build.yml's drift check).
ARG FORGEJO_SOURCE_DIGEST=""
LABEL org.forgejo-urandom-compat.source-digest="${FORGEJO_SOURCE_DIGEST}"

# Switch back to the original non-root user so the container keeps
# running exactly as the official rootless image intends.
USER 1000
