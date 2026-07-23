; ── Test 44: Multiple FK in same table ──
$ demo

# category
id   n++
name s64 *

# user
id   n++
name s32 *

# order
id         n++
user_id    n
category_id n
amount     m

> user_id user.id
> category_id category.id
