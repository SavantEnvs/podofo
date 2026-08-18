# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) -- builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). PoDoFo is a C++17 PDF library needing a handful of system
# -dev packages (freetype, libxml2, fontconfig, plus libjpeg/libpng/libtiff for the
# ImageTest suite -- zlib/openssl already ship in the base). Everything else it needs
# (tcb-span, date, fast-float, fmt, utf8cpp, utf8proc) is vendored under 3rdparty/ and used
# by default (PODOFO_DEVENDOR_* all default OFF), so no vcpkg/conan fetch is required.
# libzstd-dev/liblzma-dev are transitive link deps pulled in via OpenSSL/libxml2's own
# pkg-config Requires.private when statically linking (see mayhem/build.sh).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); an empty value breaks clang, so it
# is never baked as ENV -- build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declared WITHOUT a default so an unset arg lets the base ENV flow through to build.sh,
# while an explicit --build-arg (including an EMPTY one, for a no-sanitizer build) overrides it.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# EXTRA apt packages PoDoFo needs beyond the base (zlib1g-dev + libssl-dev already ship
# there). Re-pin to SOURCE_DATE_EPOCH first when set, for reproducibility.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      libfreetype-dev libxml2-dev libfontconfig1-dev libzstd-dev liblzma-dev \
      libjpeg-dev libpng-dev libtiff-dev \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history,
# and the extern/resources submodule content the Catch2 suite needs -- see mayhem/build.sh)
# is copied to /mayhem; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# PoDoFo's own upstream Catch2 suite (podofo-unit, built above with NORMAL flags against
# the extern/resources fixtures) -- a failing suite fails the image.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
