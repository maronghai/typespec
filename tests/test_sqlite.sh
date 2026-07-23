#!/usr/bin/env bash
# ── TypeSpec SQLite Test Runner ──
# Compiles each .ss test file with SQLite dialect and diffs against golden output.
# Usage: ./test_sqlite.sh [test-filter]

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"

FILTER="${1:-}"

for tps_file in "$TEST_DIR"/*.ss; do
  [ -f "$tps_file" ] || continue
  base=$(basename "$tps_file" .ss)

  # Only run sqlite-* test files
  if [[ "$base" != sqlite-* ]]; then
    continue
  fi

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  expected_file="$EXPECTED_DIR/$base.sqlite.sql"
  if [ ! -f "$expected_file" ]; then
    skip "$base" "no golden file"
    continue
  fi

  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" "$tps_file" -d sqlite -o "$tmp_file" 2>/dev/null; then
    fail "$base" "compiler failed"
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
    pass "$base"
  else
    diff_output=$(diff -u "$expected_file" "$tmp_file" 2>&1 | head -20)
    fail "$base" "$diff_output"
  fi

  rm -f "$tmp_file"
done

summary "SQLite"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
