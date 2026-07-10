; ── Test 77: Auto FK inference from _id suffix ──
$ demo autofk

# user

id    n++
name  s32 *
email s128 *

# order

id        n++
order_no  s64 *
user_id   n
amount    m *
