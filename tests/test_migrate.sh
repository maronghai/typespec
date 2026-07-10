#!/usr/bin/env bash
# ── TypeSpec Migration Test Runner ──
# Tests the `typespec migrate` subcommand with golden-file comparison.
# Each test has: migrate-<name>-old.tps, migrate-<name>-new.tps, expected/migrate-<name>.sql
# Usage: ./test_migrate.sh [test-filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  echo "Run 'cd zig-typespec && zig build' first."
  exit 1
fi

FILTER="${1:-}"
PASS=0
FAIL=0
ERRORS=""

# Find all migration test pairs (old files)
for old_file in "$TEST_DIR"/migrate-*-old.tps; do
  [ -f "$old_file" ] || continue
  base=$(basename "$old_file" .tps)
  # Strip the -old suffix: migrate-foo-old → migrate-foo
  base="${base%-old}"

  # Apply filter (match against full base name)
  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  new_file="$TEST_DIR/${base}-new.tps"
  expected_file="$EXPECTED_DIR/${base}.sql"

  if [ ! -f "$new_file" ]; then
    echo "SKIP  $base  (no new.tps)"
    continue
  fi
  if [ ! -f "$expected_file" ]; then
    echo "SKIP  $base  (no golden file)"
    continue
  fi

  # Generate migration SQL
  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" migrate "$old_file" "$new_file" -o "$tmp_file" 2>/dev/null; then
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
    diff -u "$expected_file" "$tmp_file" | head -30
    echo ""
    FAIL=$((FAIL + 1))
  fi

  rm -f "$tmp_file"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "Migration tests: $PASS/$TOTAL passed, $FAIL failed"
if [ -n "$ERRORS" ]; then
  echo "Errors:$ERRORS"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
