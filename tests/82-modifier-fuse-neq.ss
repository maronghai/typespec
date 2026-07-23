; ── Test 82: *= modifier fusion (NOT NULL + DEFAULT) ──
$ demo

# user

id          n++
name        s32 *=0
email       s128
is_active   b *=1
status      1 *=0 [0,1,2]
balance     m *=0.00
role        s32 =admin
