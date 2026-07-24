#!/usr/bin/env bash
# ── Rune Migration Test Runner ──
# Tests: rune migrate <old.ss> <new.ss> produces expected migration SQL.
# Runs each test for all available dialects (mysql, pg, sqlite).
# Usage: ./test_migrate.sh [test-filter]

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"

FILTER="${1:-}"

for old_file in "$TEST_DIR"/migrate-*-old.ss; do
  [ -f "$old_file" ] || continue
  base=$(basename "$old_file" .ss)
  base="${base%-old}"

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  new_file="$TEST_DIR/${base}-new.ss"

  if [ ! -f "$new_file" ]; then
    skip "$base" "no new.ss"
    continue
  fi

  for dialect_suffix in "" pg sqlite; do
    case "$dialect_suffix" in
      "")    dialect="mysql"; suffix=".sql" ;;
      pg)    dialect="pg";    suffix=".pg.sql" ;;
      sqlite) dialect="sqlite"; suffix=".sqlite.sql" ;;
    esac

    expected_file="$EXPECTED_DIR/${base}${suffix}"
    if [ ! -f "$expected_file" ]; then
      continue
    fi

    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT

    if ! "$COMPILER" migrate "$old_file" "$new_file" -d "$dialect" -o "$tmp_file" 2>/dev/null; then
      fail "$base ($dialect)" "compiler failed"
      rm -f "$tmp_file"
      continue
    fi

    if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
      pass "$base ($dialect)"
    else
      diff_output=$(diff -u "$expected_file" "$tmp_file" 2>&1 | head -20)
      fail "$base ($dialect)" "$diff_output"
    fi

    rm -f "$tmp_file"
  done
done

summary "Migration"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
