#!/usr/bin/env bash
# ── TypeSpec JSON Schema Test Runner ──
# Tests: rune --target json-schema produces expected JSON Schema output.

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TEST_DIR="$SCRIPT_DIR"
EXPECTED_DIR="$SCRIPT_DIR/expected"

FILTER="${1:-}"

for tps_file in "$TEST_DIR"/json-schema-*.ss; do
  [ -f "$tps_file" ] || continue
  base=$(basename "$tps_file" .ss)

  if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
    continue
  fi

  expected_file="$EXPECTED_DIR/${base}.json"
  if [ ! -f "$expected_file" ]; then
    skip "$base" "no expected file"
    continue
  fi

  tmp_file=$(mktemp)
  trap 'rm -f "$tmp_file"' EXIT

  if ! "$COMPILER" "$tps_file" --target json-schema -o "$tmp_file" 2>/dev/null; then
    fail "$base" "compile failed"
    rm -f "$tmp_file"
    continue
  fi

  if diff -u "$expected_file" "$tmp_file" >/dev/null 2>&1; then
    pass "$base"
  else
    fail "$base" "output differs"
    diff -u "$expected_file" "$tmp_file" | head -20
  fi

  rm -f "$tmp_file"
done

summary "JSON Schema"
