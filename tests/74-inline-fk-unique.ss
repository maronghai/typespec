; ── Test 74: Inline FK + inline unique ──
$ demo

# auth
email s128 *

# user
id    n++
email s128 * @u > auth.email
name  s32 *
