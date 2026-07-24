#!/bin/bash
# Rune Compiler Benchmark Suite
# Measures compilation time for different schema sizes

set -e

COMPILER="rune/zig-out/bin/rune.exe"
ITERATIONS=50

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found. Building..."
    cd rune && zig build -Doptimize=ReleaseSafe && cd ..
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Rune Compiler Benchmark Suite               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Iterations per scenario: $ITERATIONS"
echo ""

bench_file() {
    local name="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        echo "  ⚠ Skipping $name (file not found: $file)"
        return
    fi

    # Warmup
    for i in $(seq 1 3); do
        $COMPILER "$file" > /dev/null 2>&1
    done

    # Benchmark
    local times=()
    for i in $(seq 1 $ITERATIONS); do
        local start=$(date +%s%N)
        $COMPILER "$file" > /dev/null 2>&1
        local end=$(date +%s%N)
        local elapsed=$(( (end - start) / 1000 ))
        times+=($elapsed)
    done

    # Calculate stats
    local sum=0
    local min=999999
    local max=0
    for t in "${times[@]}"; do
        sum=$((sum + t))
        if [ $t -lt $min ]; then min=$t; fi
        if [ $t -gt $max ]; then max=$t; fi
    done
    local avg=$((sum / ITERATIONS))

    echo "━━━ $name ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Average:  ${avg} µs"
    echo "  Min:      ${min} µs"
    echo "  Max:      ${max} µs"
    local throughput=$(echo "scale=1; 1000000 / $avg" | bc 2>/dev/null || echo "N/A")
    echo "  Throughput: ${throughput} compiles/sec"
    echo ""
}

# Generate synthetic schemas
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Tiny: 3 tables, ~5 fields
cat > "$TMPDIR/tiny.ss" << 'EOF'
$ bench_tiny

% base
id n++
...
created_at +

# base user
name s64 *
email s128 *

# base post
title s128 *
body S *

# base comment
text S *
EOF

# Medium: 20 tables, ~10 fields
cat > "$TMPDIR/medium.ss" << 'EOF'
$ bench_medium

% base
id n++
...
created_at +
updated_at +

# base user
username s32 *
email s128 *
password_hash s255 *
avatar_url s512
is_active b *

# base role
name s32 *
description S

# base user_role
user_id n *
role_id n *

# base post
title s255 *
slug s255 *
body S *
status s16 *
author_id n *

# base category
name s64 *
slug s64 *
parent_id n

# base post_category
post_id n *
category_id n *

# base tag
name s32 *
slug s32 *

# base post_tag
post_id n *
tag_id n *

# base comment
body S *
author_id n *
post_id n *
parent_id n

# base media
filename s255 *
mime_type s64 *
size n *
alt_text s255

# base setting
key s128 *
value S
group s32 *

# base audit_log
action s32 *
entity_type s32 *
entity_id n *
old_value S
new_value S
user_id n

# base notification
type s32 *
message S *
read_at +
user_id n *

# base session
token s255 *
ip_address s45
user_agent s512
user_id n *

# base password_reset
email s128 *
token s255 *
expires_at +

# base api_key
key s255 *
name s64 *
permissions S
user_id n *

# base webhook
url s512 *
secret s255
events S *
active b *
EOF

# Large: use the complex example if available
if [ -f "schemaspec/examples/complex-ecommerce.ss" ]; then
    cp "schemaspec/examples/complex-ecommerce.ss" "$TMPDIR/large.ss"
fi

# Run benchmarks
bench_file "tiny (3 tables, ~5 fields)" "$TMPDIR/tiny.ss"
bench_file "medium (20 tables, ~10 fields)" "$TMPDIR/medium.ss"
if [ -f "$TMPDIR/large.ss" ]; then
    bench_file "large (complex-ecommerce)" "$TMPDIR/large.ss"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done."
