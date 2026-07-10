; ── Test 76: FK shorthand-no-dot standalone form ──
$ demo

# user
id   n++
name s32

# order
id        n++
order_no  s64 *
user_id   n *
> user_id user
amount    m *
