; ── Test 75: Composite index auto-naming ──
$ demo

# user
id    n++
name  s32
email s128
status 1 =0
create_at t+

@ (name, email)
@u (email, status)
