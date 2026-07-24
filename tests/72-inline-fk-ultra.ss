; ── Test 72: Ultra inline FK (infer local field) ──
$ demo

# user
id    n++

# order
id        n++ > user.id
order_no  s64 *
amount    m *
