#!/usr/bin/env bash
# ── TypeSpec Reverse Test Runner ──
# Tests: typespec reverse <sql> [-d dialect] produces expected .tps output.
# Usage: ./test_reverse.sh [test-filter]

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR/reverse"

FILTER="${1:-}"

for sql_file in "$TEST_DIR"/*.sql; do
  [ -f "$sql_file" ] || continue
  base=$(basename "$sql_file" .sql)

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  for dialect_suffix in mysql pg sqlite; do
    expected_file="$TEST_DIR/$base.$dialect_suffix.tps"
    if [ ! -f "$expected_file" ]; then
      continue
    fi

    case "$dialect_suffix" in
      mysql)  dialect="mysql" ;;
      pg)     dialect="pg" ;;
      sqlite) dialect="sqlite" ;;
    esac

    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT

    if ! "$COMPILER" reverse "$sql_file" -d "$dialect" -o "$tmp_file" 2>/dev/null; then
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

summary "Reverse"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
