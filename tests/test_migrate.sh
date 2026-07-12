#!/usr/bin/env bash
# ── TypeSpec Migration Test Runner ──
# Tests: typespec migrate <old.tps> <new.tps> produces expected migration SQL.
# Usage: ./test_migrate.sh [test-filter]

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"

FILTER="${1:-}"

for old_file in "$TEST_DIR"/migrate-*-old.tps; do
  [ -f "$old_file" ] || continue
  base=$(basename "$old_file" .tps)
  base="${base%-old}"

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  new_file="$TEST_DIR/${base}-new.tps"
  expected_file="$EXPECTED_DIR/${base}.sql"

  if [ ! -f "$new_file" ]; then
    skip "$base" "no new.tps"
    continue
  fi
  if [ ! -f "$expected_file" ]; then
    skip "$base" "no golden file"
    continue
  fi

  tmp_file=$(mktemp)
  trap "rm -f '$tmp_file'" EXIT

  if ! "$COMPILER" migrate "$old_file" "$new_file" -o "$tmp_file" 2>/dev/null; then
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

summary "Migration"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
