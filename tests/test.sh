#!/usr/bin/env bash
# ── TypeSpec Test Runner ──
# Compiles each .tps test file and diffs against golden .sql output.
# Usage: ./test.sh [test-filter]
#   e.g. ./test.sh           — run all tests
#        ./test.sh 01         — run tests matching "01"
#        ./test.sh template   — run tests matching "template"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

# Ensure compiler exists
if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  echo "Run 'cd zig-typespec && zig build' first."
  exit 1
fi

FILTER="${1:-}"
PASS=0
FAIL=0
ERRORS=""

for tps_file in "$TEST_DIR"/*.tps; do
  [ -f "$tps_file" ] || continue
  base=$(basename "$tps_file" .tps)

  # Apply filter
  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  expected_file="$EXPECTED_DIR/$base.sql"
  if [ ! -f "$expected_file" ]; then
    echo "SKIP  $base  (no golden file)"
    continue
  fi

  # Compile to temp file
  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" "$tps_file" -o "$tmp_file" 2>/dev/null; then
    echo "ERROR $base  (compiler failed)"
    ERRORS="$ERRORS $base"
    FAIL=$((FAIL + 1))
    rm -f "$tmp_file"
    continue
  fi

  # Compare
  if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
    echo "PASS  $base"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $base"
    diff -u "$expected_file" "$tmp_file" 2>&1 | head -30 || true
    echo ""
    FAIL=$((FAIL + 1))
  fi

  rm -f "$tmp_file"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [ -n "$ERRORS" ]; then
  echo "Errors:$ERRORS"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
