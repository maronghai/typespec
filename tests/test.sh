#!/usr/bin/env bash
# ── TypeSpec Test Runner ──
# Compiles each .ss test file and diffs against golden .sql output.
# Usage: ./test.sh [test-filter]
#   e.g. ./test.sh           — run all tests
#        ./test.sh 01         — run tests matching "01"
#        ./test.sh template   — run tests matching "template"

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"

FILTER="${1:-}"

for ss_file in "$TEST_DIR"/*.ss; do
  [ -f "$ss_file" ] || continue
  base=$(basename "$ss_file" .ss)

  # Apply filter
  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  # Skip SQLite-only test files
  if [[ "$base" == sqlite-* ]]; then
    continue
  fi

  expected_file="$EXPECTED_DIR/$base.sql"
  if [ ! -f "$expected_file" ]; then
    skip "$base" "no golden file"
    continue
  fi

  # Compile to temp file
  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" "$ss_file" -o "$tmp_file" 2>/dev/null; then
    fail "$base" "compiler failed"
    rm -f "$tmp_file"
    continue
  fi

  # Compare
  if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
    pass "$base"
  else
    diff_output=$(diff -u "$expected_file" "$tmp_file" 2>&1 | head -20)
    fail "$base" "$diff_output"
  fi

  rm -f "$tmp_file"
done

summary "MySQL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
