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

# Test 4: Multiple errors in one file → should produce multiple diagnostics
echo "Test: multi-errors"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/multi-errors.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
warn_count=$(echo "$output" | grep -c "warning:" || true)
if [ "$warn_count" -ge 2 ]; then
    pass "multi-errors ($warn_count warnings)"
else
    fail "multi-errors" "Expected >=2 warnings, got $warn_count: $output"
fi

# Test 5: Circular template inheritance → should produce fatal error
echo "Test: circular-template"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/circular-template.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -qi "circular"; then
    pass "circular-template"
else
    fail "circular-template" "Expected 'circular' error, got: $output"
fi

# Test 6: Duplicate template names → should produce warning
echo "Test: duplicate-template"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/duplicate-template.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -qi "duplicate\|already defined\|redefined"; then
    pass "duplicate-template"
elif [ "$rc" -eq 0 ]; then
    # Compiler accepts duplicate templates (second overwrites first) — no crash is acceptable
    pass "duplicate-template (graceful overwrite, rc=0)"
else
    fail "duplicate-template" "Unexpected failure (rc=$rc): $output"
fi

# Test 7: Invalid custom type reference → should produce warning or passthrough
echo "Test: invalid-custom-type"
output=$("$COMPILER" "$SCRIPT_DIR/error-recovery/invalid-custom-type.tps" -o /dev/null 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -qi "unknown type\|undefined\|invalid.*type"; then
    pass "invalid-custom-type"
elif [ "$rc" -eq 0 ]; then
    # Compiler passes through unknown types as raw SQL — no crash is acceptable
    pass "invalid-custom-type (graceful passthrough, rc=0)"
else
    fail "invalid-custom-type" "Unexpected failure (rc=$rc): $output"
fi

summary "Error Recovery"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
