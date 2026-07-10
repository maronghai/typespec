; ── Test 86: FK trailing dot infers ref_field from local field ──
$ demo

# user
id   n++
name s32

# order
id        n++
order_no  s64 *
user_id   n *
> order_no order.
amount    m *
