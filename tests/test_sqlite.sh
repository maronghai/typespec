#!/usr/bin/env bash
# ── TypeSpec SQLite Test Runner ──
# Compiles each .tps test file with SQLite dialect and diffs against golden output.
# Usage: ./test_sqlite.sh [test-filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  exit 1
fi

FILTER="${1:-}"
PASS=0
FAIL=0

for tps_file in "$TEST_DIR"/*.tps; do
  [ -f "$tps_file" ] || continue
  base=$(basename "$tps_file" .tps)

  # Skip migration test pairs
  if [[ "$base" == migrate-* ]]; then
    continue
  fi

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  expected_file="$EXPECTED_DIR/$base.sqlite.sql"
  if [ ! -f "$expected_file" ]; then
    continue
  fi

  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" "$tps_file" -d sqlite -o "$tmp_file" 2>/dev/null; then
    echo "ERROR $base  (compiler failed)"
    FAIL=$((FAIL + 1))
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
    echo "PASS  $base"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $base"
    diff -u "$expected_file" "$tmp_file" 2>&1 | head -20 || true
    echo ""
    FAIL=$((FAIL + 1))
  fi

  rm -f "$tmp_file"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "SQLite Results: $PASS/$TOTAL passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
