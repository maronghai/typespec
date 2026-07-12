#!/bin/bash
# ── TypeSpec Test Library ──
# Shared functions for all test runners.
# Source this file: source "$(dirname "$0")/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPILER="$PROJECT_DIR/zig-typespec/zig-out/bin/typespec.exe"

# Ensure compiler exists
if [ ! -f "$COMPILER" ]; then
  echo "ERROR: Compiler not found at $COMPILER"
  echo "Run 'cd zig-typespec && zig build' first."
  exit 1
fi

PASS=0
FAIL=0
SKIP=0
ERRORS=""

pass() {
  printf "  \033[32m✅\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31m❌\033[0m %s\n" "$1"
  if [ -n "${2:-}" ]; then
    printf "     \033[90m%s\033[0m\n" "$2"
  fi
  FAIL=$((FAIL + 1))
  ERRORS="$ERRORS $1"
}

skip() {
  printf "  \033[33m⏭\033[0m  %s  (%s)\n" "$1" "${2:-skipped}"
  SKIP=$((SKIP + 1))
}

header() {
  echo ""
  printf "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
  printf "\033[1m%s\033[0m\n" "$1"
  printf "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
  echo ""
}

summary() {
  local label="${1:-Tests}"
  local total=$((PASS + FAIL))
  echo ""
  printf "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
  if [ $FAIL -eq 0 ]; then
    printf "\033[32m%s: %d/%d passed\033[0m\n" "$label" "$PASS" "$total"
  else
    printf "\033[31m%s: %d/%d passed, %d failed\033[0m\n" "$label" "$PASS" "$total" "$FAIL"
  fi
  if [ $SKIP -gt 0 ]; then
    printf "\033[33m  (%d skipped)\033[0m\n" "$SKIP"
  fi
  if [ -n "$ERRORS" ]; then
    printf "\033[31mFailed:%s\033[0m\n" "$ERRORS"
  fi
  printf "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
}
