#!/usr/bin/env bash
# ── TypeSpec Reverse Test Runner ──
# Tests: typespec reverse <sql> [-d dialect] produces expected .tps output.
# Usage: ./test_reverse.sh [test-filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/reverse"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  exit 1
fi

FILTER="${1:-}"
PASS=0
FAIL=0

for sql_file in "$TEST_DIR"/*.sql; do
  [ -f "$sql_file" ] || continue
  base=$(basename "$sql_file" .sql)

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  # Check for dialect-specific golden files (.mysql.tps, .pg.tps, .sqlite.tps)
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
      echo "ERROR $base ($dialect)  (compiler failed)"
      FAIL=$((FAIL + 1))
      rm -f "$tmp_file"
      continue
    fi

    if diff -u "$expected_file" "$tmp_file" > /dev/null 2>&1; then
      echo "PASS  $base ($dialect)"
      PASS=$((PASS + 1))
    else
      echo "FAIL  $base ($dialect)"
      diff -u "$expected_file" "$tmp_file" 2>&1 | head -20 || true
      echo ""
      FAIL=$((FAIL + 1))
    fi

    rm -f "$tmp_file"
  done
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo "Reverse tests: $PASS/$TOTAL passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
