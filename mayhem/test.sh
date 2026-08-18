#!/usr/bin/env bash
#
# podofo/mayhem/test.sh -- RUN PoDoFo's own upstream Catch2 test suite (`podofo-unit`,
# built by mayhem/build.sh via the project's normal CMake flags against the
# extern/resources fixtures) and emit a CTRF summary. exit 0 iff nothing failed.
#
# BEHAVIORAL oracle (SPEC 6.3 anti-reward-hacking). `podofo-unit` is PoDoFo's own upstream
# test aggregator (test/unit/*.cpp, ~29 TEST_CASE files, ~803 individual REQUIRE
# assertions run via Catch2): it decodes/encodes real PDF fixtures and asserts exact
# VALUES (parsed dictionary entries, decoded stream bytes, extracted text, xref offsets,
# encryption round-trips, ...), not just "did not crash". A no-op/exit(0) patch to the
# library would make individual REQUIRE()s fail their comparisons, which Catch2 counts and
# reports in its JUnit XML -- not a stub that survives.
#
# podofo-unit is a plain, dynamically-linked clang++ executable (asserted by build.sh) --
# unlike a statically-linked `go test`/`cargo test` binary, the verify-repo LD_PRELOAD
# sabotage shim CAN neuter it (constructor _exit(0)s it before main() runs, and therefore
# before Catch2 ever gets to write its JUnit report) -- the "no XML produced" check below
# then fails outright, so this oracle is caught by the mechanical sabotage check without a
# separate cgo-style probe.
#
# This script does NOT compile -- mayhem/build.sh already built podofo-unit.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/mayhem-build/podofo-unit"
if [ ! -x "$BIN" ]; then
  echo "missing $BIN -- run mayhem/build.sh first" >&2
  emit_ctrf "podofo-catch2-unit" 0 1 0
  exit 2
fi

XML_OUT="$(mktemp /tmp/podofo-unit-XXXXXX.xml)"
trap 'rm -f "$XML_OUT"' EXIT

echo "=== running: $BIN --reporter junit --out $XML_OUT ==="
STDOUT_LOG="$("$BIN" --reporter junit --out "$XML_OUT" 2>&1)"; rc=$?
printf '%s\n' "$STDOUT_LOG"

# UNCONDITIONAL: a missing/empty JUnit report is a FAILURE, never a skip -- this is exactly
# what a neutered (exit(0)'d before main/Catch2 ever runs), crashed, or missing binary
# produces.
if [ ! -s "$XML_OUT" ]; then
  echo "FAIL: podofo-unit produced no JUnit XML report (neutered, crashed, or missing binary) -- rc=$rc" >&2
  emit_ctrf "podofo-catch2-unit" 0 1 0
  exit 1
fi

read -r TESTS FAILURES ERRORS SKIPPED < <(python3 - "$XML_OUT" <<'PY'
import sys
import xml.etree.ElementTree as ET

def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0

try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError:
    print(0, 0, 0, 0)
    sys.exit(0)

suites = [root] if root.tag == 'testsuite' else root.findall('.//testsuite')
tests = failures = errors = skipped = 0
for s in suites:
    tests += to_int(s.get('tests'))
    failures += to_int(s.get('failures'))
    errors += to_int(s.get('errors'))
    skipped += to_int(s.get('skipped'))
print(tests, failures, errors, skipped)
PY
)
: "${TESTS:=0}" "${FAILURES:=0}" "${ERRORS:=0}" "${SKIPPED:=0}"

if [ "$TESTS" -eq 0 ]; then
  echo "FAIL: JUnit report shows 0 test cases -- the suite did not execute" >&2
  emit_ctrf "podofo-catch2-unit" 0 1 0
  exit 1
fi

FAILED=$(( FAILURES + ERRORS ))
PASSED=$(( TESTS - FAILED - SKIPPED ))
if [ "$PASSED" -lt 0 ]; then PASSED=0; fi

# A nonzero exit with a clean-looking report (e.g. a crash AFTER the XML was written, or a
# signal) is inconsistent -- stay honest rather than silently reporting green.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "FAIL: podofo-unit exited $rc despite the JUnit report showing 0 failures -- treating as a failure" >&2
  FAILED=1
  PASSED=$(( PASSED > 0 ? PASSED - 1 : 0 ))
fi

echo "=== results: $TESTS test cases, $PASSED passed, $FAILED failed, $SKIPPED skipped ==="
emit_ctrf "podofo-catch2-unit" "$PASSED" "$FAILED" "$SKIPPED"
