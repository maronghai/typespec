; ── Test 24: Multiple tables with SQL comments between ──
$ demo

-- Users table
# user
id   n++
name s32 *

-- Orders table
# order
id      n++
user_id n
amount  m

> user_id user.id
