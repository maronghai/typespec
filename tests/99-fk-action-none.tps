; ── Test 99: FK action — no actions (default RESTRICT) ──
$ demo

# user
id   n++
name s32 *

# order
id      n++
user_id n
amount  m

> user_id user.id
