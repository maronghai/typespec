; ── Test 71: Inline FK without arrow ──
$ demo

# user
id    n++

# order
id        n++
order_no  s64 *
user_id   n user.id
amount    m *
