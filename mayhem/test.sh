#!/usr/bin/env bash
#
# mpv/mayhem/test.sh — RUN the mayhem_kat behavioral oracle (built by mayhem/build.sh) and emit a
# CTRF summary. exit 0 iff the known-answer round-trip through mpv's REAL property-dispatch code
# succeeded. See mayhem/harnesses/mayhem_kat.c for what it asserts and why.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

BIN="./mayhem_kat"
EXPECT_MARK="MAYHEM_KAT_OK expect=mayhem-kat-4f9c2b17 got=mayhem-kat-4f9c2b17"

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

if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  emit_ctrf "mayhem-kat" 0 1; exit 2
fi

# mayhem_kat is a libFuzzer binary whose LLVMFuzzerTestOneInput() ignores its input and always runs
# the same deterministic check; libFuzzer's "replay a single file" mode needs SOME file argument.
SEED="$(mktemp)"
printf 'x' > "$SEED"
out="$("$BIN" "$SEED" 2>&1)"; rc=$?
rm -f "$SEED"
echo "=== mayhem_kat output ==="
echo "$out"

if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$EXPECT_MARK"; then
  echo "mayhem_kat: known-answer round-trip through mpv's property dispatch PASSED"
  emit_ctrf "mayhem-kat" 1 0
  exit 0
else
  echo "mayhem_kat: FAILED (rc=$rc, expected marker '$EXPECT_MARK' not found)" >&2
  emit_ctrf "mayhem-kat" 0 1
  exit 1
fi
