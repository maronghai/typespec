; ── Test 85: FK shorthand without dot ──
$ demo

# user
id   n++
name s32

# order
id        n++
order_no  s64 *
user_id   n             ; field_name ref_table (no dot)
> user_id user
amount    m *
