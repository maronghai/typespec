#!/usr/bin/env bash
# ── TypeSpec Diff Test Runner ──
# Tests: typespec diff <old.tps> <new.tps> produces expected diff output.
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

  old_file="$TEST_DIR/${base}-old.tps"
  new_file="$TEST_DIR/${base}-new.tps"
  same_file="$TEST_DIR/${base}.tps"

  if [ -f "$same_file" ]; then
    old_file="$same_file"
    new_file="$same_file"
  elif [ ! -f "$old_file" ] || [ ! -f "$new_file" ]; then
    skip "$base" "missing input files"
    continue
  fi

  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" diff "$old_file" "$new_file" -d mysql > "$tmp_file" 2>/dev/null; then
    fail "$base" "compiler failed"
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$diff_file" "$tmp_file" > /dev/null 2>&1; then
    pass "$base"
  else
    diff_output=$(diff -u "$diff_file" "$tmp_file" 2>&1 | head -20)
    fail "$base" "$diff_output"
  fi

  rm -f "$tmp_file"
done

summary "Diff"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
