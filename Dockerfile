# syntax=docker/dockerfile:1

# ==============================================================================
# Reference: the official Forgejo image, used twice below
# (once as the build base, once as the final base)
# ==============================================================================
FROM codeberg.org/forgejo/forgejo:15-rootless AS forgejo-original

# ==============================================================================
# Build stage: compile Git INSIDE the official image itself, statically.
# Guarantees the same Alpine base/Git version as the original, and produces
# a fully self-contained binary (no shared dependencies).
# ==============================================================================
FROM forgejo-original AS git-builder

# The rootless image runs as a non-root user (UID 1000) by default.
# apk needs root privileges to write to /var/lib/apk and /var/cache/apk.
USER root

# Build dependencies. On recent Alpine releases, static libraries (.a files)
# were split out of the regular -dev packages into dedicated -static
# packages, so both are needed for a fully static -static link.
RUN apk add --no-cache \
        build-base \
        autoconf \
        pkgconf \
        curl-dev \
        curl-static \
        expat-dev \
        expat-static \
        pcre2-dev \
        pcre2-static \
        zlib-dev \
        zlib-static \
        openssl-dev \
        openssl-libs-static \
        nghttp2-static \
        brotli-static \
        zstd-static \
        libpsl-static \
        libidn2-static \
        libunistring-static

WORKDIR /usr/src

# Dynamic detection: query the Git already installed in this image (the
# apk one), since we're literally running inside it.
RUN GIT_VERSION="$(git --version | awk '{print $3}')" \
    && echo "Git version detected in the official image: ${GIT_VERSION}" \
    && curl -fsSL "https://github.com/git/git/archive/refs/tags/v${GIT_VERSION}.tar.gz" \
        -o git.tar.gz \
    && tar xzf git.tar.gz \
    && mv "git-${GIT_VERSION}" git

WORKDIR /usr/src/git

# CRITICAL points:
# - CSPRNG_METHOD="" (explicitly empty): Git's own config.mak.uname
#   automatically forces CSPRNG_METHOD=getrandom for any system detected
#   as "Linux" -- regardless of whether we set it ourselves. Simply never
#   mentioning it is NOT enough. We must explicitly override it on the
#   make command line (which always takes priority over an in-Makefile
#   assignment) to force the /dev/urandom fallback path instead of
#   getrandom(2). This is what makes it work on old kernels (e.g. 3.10).
# - LDFLAGS="-static" -> static binary, no dependency on musl/libcurl/etc.
# - LDFLAGS also includes "-Wl,--allow-multiple-definition": Git's own
#   usage.c defines a function called error(), and libidn2 (a transitive
#   static dependency of curl) bundles a gnulib replacement also called
#   error(). This is harmless in dynamic linking but clashes at static
#   link time; this flag tells the linker to keep the first definition
#   it sees instead of failing.
# - CURL_LIBCURL: Git's own curl-config-based detection (CURL_STATIC=YesPlease)
#   turned out to be incomplete on this Alpine version (missing OpenSSL,
#   nghttp2, c-ares, libpsl, brotli, zstd in the link line). We bypass it
#   entirely and compute the correct static link flags ourselves via
#   `pkg-config --static`, which reads the standard "Libs.private" field
#   and reliably includes curl's full static dependency chain, in order.
RUN CURL_LIBCURL="$(pkg-config --static --libs libcurl)" \
    && echo "Resolved static curl libs: ${CURL_LIBCURL}" \
    && make configure \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" \
        LDFLAGS="-static -Wl,--allow-multiple-definition" \
        CURL_LIBCURL="${CURL_LIBCURL}" \
        CSPRNG_METHOD= \
        NO_GETTEXT=1 \
        NO_PERL=1 \
        NO_TCLTK=1 \
        NO_GITWEB=1 \
        DESTDIR=/build \
        install

# Sanity check: confirm the /dev/urandom fallback path was actually
# compiled in, instead of a direct getrandom(2)/getentropy() call.
# The fallback path needs the literal string "/dev/urandom" embedded in
# the binary (as the path passed to open()); if HAVE_GETRANDOM had been
# set instead, this string would not be needed for random byte
# generation at all. This is a much more reliable check than inspecting
# build variables, since it looks at what actually ended up in the
# compiled binary.
RUN if strings /build/usr/bin/git | grep -q "^/dev/urandom$"; then \
        echo "OK: /dev/urandom fallback found in the compiled binary"; \
    else \
        echo "ERROR: /dev/urandom string not found -- getrandom() may still be in use!" && exit 1; \
    fi

# Sanity check: verify the binary works AND is actually static.
# Note: `file` may report "static-pie linked" instead of "statically
# linked" -- this is still a fully static, self-contained binary (no
# shared library dependencies), just built as a position-independent
# executable. Both forms are accepted here.
RUN /build/usr/bin/git --version \
    && (file /build/usr/bin/git | grep -qE "statically linked|static-pie linked" \
        && echo "OK: static binary confirmed" \
        || (echo "WARNING: the binary does not appear to be static!" && file /build/usr/bin/git))

# ==============================================================================
# Final image: start again from the untouched official image, remove the
# apk git package (so a future apk upgrade can't overwrite it), then copy
# our statically-linked binary in its place.
# ==============================================================================
FROM forgejo-original

# Same reason as above: apk del needs root.
USER root

RUN apk del --no-cache git \
    && rm -rf /var/cache/apk/*

COPY --from=git-builder /build/usr/bin/git* /usr/bin/
COPY --from=git-builder /build/usr/libexec/git-core/ /usr/libexec/git-core/
COPY --from=git-builder /build/usr/share/git-core/ /usr/share/git-core/

RUN git --version

# Switch back to the original non-root user so the container keeps
# running exactly as the official rootless image intends.
USER 1000
