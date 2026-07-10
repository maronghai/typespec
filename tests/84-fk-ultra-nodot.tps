; ── Test 84: FK ultra shorthand without .id ──
$ demo

# user
id   n++
name s32

# order
id        n++
order_no  s64 *
user_id   n             ; declared separately, FK inferred below
> user
amount    m *

# payment
id        n++
user_id   n             ; declared separately, FK inferred below
> user
amount    m *
