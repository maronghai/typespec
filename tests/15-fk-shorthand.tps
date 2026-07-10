; ── Test 15: Foreign key — shorthand form ──
$ demo

# user
id   n++
name s32 *

# order
id      n++
user_id n
amount  m

> user_id user.id
