; ── Test 37: FK basic form ──
$ demo

# user
id   n++
name s32 *

# order
id      n++
user_id n

> user_id user.id
