#!/usr/bin/env bash
# ── TypeSpec Diff Test Runner ──
# Tests: typespec diff <old.tps> <new.tps> produces expected diff output.
# Usage: ./test_diff.sh [test-filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/diff"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  exit 1
fi

FILTER="${1:-}"
PASS=0
FAIL=0

for diff_file in "$TEST_DIR"/*.diff.txt; do
  [ -f "$diff_file" ] || continue
  base=$(basename "$diff_file" .diff.txt)

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  # Determine old/new TPS files from the diff name
  old_file="$TEST_DIR/${base}-old.tps"
  new_file="$TEST_DIR/${base}-new.tps"
  same_file="$TEST_DIR/${base}.tps"

  if [ -f "$same_file" ]; then
    # Same file for both old and new (no-change test)
    old_file="$same_file"
    new_file="$same_file"
  elif [ ! -f "$old_file" ] || [ ! -f "$new_file" ]; then
    echo "SKIP  $base  (missing input files)"
    continue
  fi

  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" diff "$old_file" "$new_file" -d mysql > "$tmp_file" 2>/dev/null; then
    echo "ERROR $base  (compiler failed)"
    FAIL=$((FAIL + 1))
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$diff_file" "$tmp_file" > /dev/null 2>&1; then
    echo "PASS  $base"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $base"
    diff -u "$diff_file" "$tmp_file" 2>&1 | head -20 || true
    echo ""
    FAIL=$((FAIL + 1))
  fi

  rm -f "$tmp_file"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "Diff tests: $PASS/$TOTAL passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
