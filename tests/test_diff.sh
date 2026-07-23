#!/usr/bin/env bash
# ── TypeSpec Diff Test Runner ──
# Tests: rune diff <old.ss> <new.ss> produces expected diff output.
# Usage: ./test_diff.sh [test-filter]

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR/diff"

FILTER="${1:-}"

for diff_file in "$TEST_DIR"/*.diff.txt; do
  [ -f "$diff_file" ] || continue
  base=$(basename "$diff_file" .diff.txt)

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  old_file="$TEST_DIR/${base}-old.ss"
  new_file="$TEST_DIR/${base}-new.ss"
  same_file="$TEST_DIR/${base}.ss"

  if [ -f "$same_file" ]; then
    old_file="$same_file"
    new_file="$same_file"
  elif [ ! -f "$old_file" ] || [ ! -f "$new_file" ]; then
    skip "$base" "missing input files"
    continue
  fi

  # Test with MySQL (default)
  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" diff "$old_file" "$new_file" -d mysql > "$tmp_file" 2>/dev/null; then
    fail "$base (mysql)" "compiler failed"
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$diff_file" "$tmp_file" > /dev/null 2>&1; then
    pass "$base (mysql)"
  else
    diff_output=$(diff -u "$diff_file" "$tmp_file" 2>&1 | head -20)
    fail "$base (mysql)" "$diff_output"
  fi

  rm -f "$tmp_file"

  # Test with PG/SQLite if dialect-specific golden file exists
  for dialect in pg sqlite; do
    dialect_file="$TEST_DIR/${base}.diff.${dialect}.txt"
    if [ ! -f "$dialect_file" ]; then
      continue
    fi

    tmp_file=$(mktemp)
    if ! "$COMPILER" diff "$old_file" "$new_file" -d "$dialect" > "$tmp_file" 2>/dev/null; then
      fail "$base ($dialect)" "compiler failed"
      rm -f "$tmp_file"
      continue
    fi

    if diff -u "$dialect_file" "$tmp_file" > /dev/null 2>&1; then
      pass "$base ($dialect)"
    else
      diff_output=$(diff -u "$dialect_file" "$tmp_file" 2>&1 | head -20)
      fail "$base ($dialect)" "$diff_output"
    fi

    rm -f "$tmp_file"
  done
done

summary "Diff"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
