; ── Test 78: Explicit FK overrides autofk ──
$ demo autofk

# user

id    n++
name  s32 *
email s128 *

# order

id        n++
order_no  s64 *
user_id   n > user.id
amount    m *
