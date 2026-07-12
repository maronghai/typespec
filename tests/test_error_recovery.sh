#!/usr/bin/env bash
# ── TypeSpec Error Recovery Tests ──
# Verifies that the compiler collects and reports multiple diagnostics.
# Usage: ./test_error_recovery.sh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

header "Error Recovery Tests"

# Test 1: Duplicate field names → should produce warning
echo "Test: duplicate-fields"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/duplicate-fields.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "duplicate field 'name'"; then
    pass "duplicate-fields"
else
    fail "duplicate-fields" "Expected 'duplicate field' warning, got: $output"
fi

# Test 2: FK references non-existent table → should produce error
echo "Test: fk-nonexistent-table"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/fk-nonexistent-table.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "non-existent table 'nonexistent'"; then
    pass "fk-nonexistent-table"
else
    fail "fk-nonexistent-table" "Expected 'non-existent table' error, got: $output"
fi

# Test 3: FK references non-existent field → should produce error
echo "Test: fk-nonexistent-field"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/fk-nonexistent-field.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "non-existent table 'user'" || echo "$output" | grep -q "not found in table 'order'"; then
    pass "fk-nonexistent-field"
else
    fail "fk-nonexistent-field" "Expected FK reference error, got: $output"
fi

summary "Error Recovery"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
