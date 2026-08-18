#!/usr/bin/env bash
#
# podofo/mayhem/build.sh -- build two libFuzzer harnesses over PoDoFo's in-memory PDF
# loader (+ standalone reproducers), AND PoDoFo's own upstream Catch2 test suite
# (`podofo-unit`, built via the project's normal CMake flags) for mayhem/test.sh.
#
#   fuzz_load      -- PdfMemDocument::LoadFromBuffer + a bounded page-tree walk (rect,
#                     rotation, annotations) + PdfCanvas::GetContentsCopy() (decodes the
#                     content stream through the full filter chain: FlateDecode/LZW/
#                     ASCII85/RunLength/DCT-passthrough). The core parser/xref/filter surface.
#   fuzz_load_text -- same load + walk, PLUS PdfPage::ExtractTextTo() on every page, which
#                     additionally drives the content-stream tokenizer, font program parsing
#                     (Type1/TrueType/CFF via FreeType), and CMap/encoding tables -- a very
#                     bug-rich area distinct from fuzz_load's filter-only walk.
#
# PoDoFo throws PoDoFo::PdfError on malformed input; both harnesses catch PdfError (and
# std::exception generally, e.g. bad_alloc on a rejected pathological size) as the EXPECTED
# outcome for a mostly-invalid fuzz corpus, and deliberately do NOT catch (...) blindly --
# sanitizer aborts never unwind as a C++ exception, so ASan/UBSan findings still surface.
# Each harness also bounds input size and the number of pages/annotations walked (SPEC 6b):
# a huge/looping page tree is not itself a bug, and libFuzzer cannot interrupt a stuck
# iteration, so an unbounded walk would let one malformed input stall the whole campaign;
# genuine crashes/OOM inside the bounded walk are NOT masked.
#
# The PoDoFo library itself is compiled here (not just the harnesses) with
# -fsanitize=fuzzer-no-link UNCONDITIONALLY (independent of $SANITIZER_FLAGS) so
# SanitizerCoverage is always present in the library objects, even under an explicit empty
# --build-arg SANITIZER_FLAGS= (no-sanitizer) build -- otherwise Mayhem would see 0 edges
# from the parser despite the harness translation unit itself being instrumented via
# $LIB_FUZZING_ENGINE at the final link.
#
# Dependencies: zlib + OpenSSL ship in the base image; freetype/libxml2/fontconfig are
# installed by mayhem/Dockerfile (-dev packages, baked layers -- no network at build.sh
# time). Everything else PoDoFo needs (tcb-span, date, fast-float, fmt, utf8cpp, utf8proc)
# is vendored under 3rdparty/ and used by default (PODOFO_DEVENDOR_* all default OFF), so
# there is no vcpkg/conan/FetchContent fetch to pin. libjpeg/libpng/libtiff -dev packages
# are installed too (mayhem/Dockerfile) so PdfImage's format detection/decoding is enabled
# and the upstream ImageTest suite exercises real codecs instead of failing on
# UnsupportedImageFormat/NotImplemented.
#
# PoDoFo's own Catch2 suite (test/unit, ~803 REQUIRE assertions) needs real PDF/font
# fixtures from the `extern/resources` git submodule (test/CMakeLists.txt silently disables
# the whole suite -- `PODOFO_BUILD_TEST` subtree returns() early -- if that path is
# missing). The build CONTEXT is not guaranteed to have it pre-populated (a plain `git
# clone` -- what CI-parity checks reproduce -- copies only the gitlink, not the submodule's
# content), so step 0 below fetches it ONLINE, once, the first time build.sh runs against a
# checkout that lacks it -- this happens at ordinary (networked) `docker build` time, never
# during the air-gapped re-run: once fetched, the submodule content is baked into the image
# layer, so a later `docker run --network none ... bash mayhem/build.sh` finds it already
# present and the fetch is skipped (idempotent, no network needed).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Always ensure the LIBRARY gets SanitizerCoverage instrumentation, regardless of the base
# image's default or an empty override (see header comment).
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DWARF <= 3 (SPEC 6.2 item 10): clang-19's plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS
: "${SRC:=/mayhem}"
cd "$SRC"

# ── 0) The Catch2 fixtures submodule (see header). Fetch it ONLY if not already populated --
#       a checkout that already carries it (actions/checkout with submodules: recursive, or a
#       prior build baked into this same image) needs no network at all. ─────────────────────
if [ ! -f "$SRC/extern/resources/blank.pdf" ]; then
  echo "extern/resources not populated -- fetching it once (online build only) ..."
  git -C "$SRC" submodule update --init -- extern/resources
fi
[ -f "$SRC/extern/resources/blank.pdf" ] || { echo "FATAL: extern/resources still missing blank.pdf after submodule init" >&2; exit 1; }

BUILD_ROOT="$SRC/mayhem-build"
mkdir -p "$BUILD_ROOT"

CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
  -DPODOFO_BUILD_STATIC=TRUE
  -DPODOFO_BUILD_EXAMPLES=FALSE
  -DPODOFO_BUILD_UNSUPPORTED_TOOLS=FALSE
  -DCMAKE_INSTALL_LIBDIR=lib
)

# ── 1) Sanitized library build (SanCov + ASan/UBSan + DWARF-3), installed to export a
#       proper CMake/pkg-config package (podofo-config.cmake / libpodofo.pc) so the harness
#       link line doesn't need to hand-guess PoDoFo's system dependency set. ─────────────────
FUZZ_BUILD="$BUILD_ROOT/fuzz"
FUZZ_INSTALL="$BUILD_ROOT/fuzz-install"
cmake -S "$SRC" -B "$FUZZ_BUILD" "${CMAKE_COMMON[@]}" \
  -DPODOFO_BUILD_TEST=FALSE \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_INSTALL_PREFIX="$FUZZ_INSTALL"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target install

export PKG_CONFIG_PATH="$FUZZ_INSTALL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
PODOFO_CFLAGS="$(pkg-config --cflags libpodofo)"
# --static: libpodofo.a alone is not self-contained (podofo_private/podofo_3rdparty are
# separate archives, per PoDoFo's own libpodofo.pc "Libs.private") -- pkg-config --static
# pulls those plus every transitive system lib (freetype/libxml2/fontconfig/openssl/zlib).
PODOFO_LIBS="$(pkg-config --libs --static libpodofo)"
echo "PODOFO_CFLAGS=$PODOFO_CFLAGS"
echo "PODOFO_LIBS=$PODOFO_LIBS"

# Standalone driver object, built once, linked into every harness's -standalone binary.
# Compiled as C (-x c): a C++ harness otherwise mangles its LLVMFuzzerTestOneInput symbol.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$BUILD_ROOT/standalone_main.o"

HARNESS_DIR="$SRC/mayhem/harnesses"
for h in fuzz_load fuzz_load_text; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $PODOFO_CFLAGS \
      "$HARNESS_DIR/$h.cpp" $LIB_FUZZING_ENGINE $PODOFO_LIBS \
      -o "/mayhem/$h"

  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $PODOFO_CFLAGS \
      "$HARNESS_DIR/$h.cpp" "$BUILD_ROOT/standalone_main.o" $PODOFO_LIBS \
      -o "/mayhem/$h-standalone"

  echo "built $h (+ standalone)"
done

# ── 2) PoDoFo's OWN Catch2 KAT suite (`podofo-unit`), a SEPARATE clean CMake tree, project
#       NORMAL flags (no sanitizer, no DWARF override) -- an honest, non-triage oracle build.
#       This coexists fine with step 1: separate build dir, no make-clean/stash dance needed. ─
TEST_BUILD="$BUILD_ROOT/test"
cmake -S "$SRC" -B "$TEST_BUILD" "${CMAKE_COMMON[@]}" \
  -DPODOFO_BUILD_TEST=TRUE \
  -DCMAKE_BUILD_TYPE=Release \
  ${COVERAGE_FLAGS:+-DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"}
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target podofo-unit

UNIT_BIN="$TEST_BUILD/target/podofo-unit"
if [ ! -x "$UNIT_BIN" ]; then
  UNIT_BIN="$(find "$TEST_BUILD" -maxdepth 4 -type f -name podofo-unit | head -1)"
fi
[ -n "$UNIT_BIN" ] && [ -x "$UNIT_BIN" ] || { echo "FATAL: podofo-unit was not produced by 'cmake --build --target podofo-unit'" >&2; exit 1; }

# podofo-unit MUST be dynamically linked so verify-repo's LD_PRELOAD sabotage shim can
# neuter it -- a statically-linked test binary would survive sabotage and make
# mayhem/test.sh a reward-hackable oracle (SPEC 6.3). Plain clang/clang++ links dynamically
# by default; assert it so a toolchain change can't silently flip this.
if ! file "$UNIT_BIN" | grep -q 'dynamically linked'; then
  echo "FATAL: $UNIT_BIN is not dynamically linked -- the sabotage check could not neuter it," >&2
  echo "       which would make mayhem/test.sh a reward-hackable oracle." >&2
  file "$UNIT_BIN" >&2
  exit 1
fi

# Stable path for mayhem/test.sh (independent of the exact CMake build-dir layout above).
ln -sf "$UNIT_BIN" "$BUILD_ROOT/podofo-unit"
echo "built podofo-unit (dynamically linked Catch2 KAT runner) at $UNIT_BIN"

echo "build.sh complete:"
ls -la /mayhem/fuzz_load /mayhem/fuzz_load_text \
       /mayhem/fuzz_load-standalone /mayhem/fuzz_load_text-standalone \
       "$UNIT_BIN" 2>&1 || true
