; ── Constraints Example ──
; Demonstrates CHECK constraints and composite keys

$ demo

; ── User Table with CHECK constraints ──
# user

id          n++
username    s32 *
email       s128 *
age         n =0 [0,150]
status      1 =0 [0,1,2]
balance     m =0 [>=0]
score       M =0 [0,100]

@! uk_email (email)

; ── User Role (composite primary key) ──
# user_role

user_id n!
role_id n!

; ── Order with CHECK constraints ──
# order

id          n++
order_no    s64 *
user_id     n
amount      m [>0]
quantity    n =1 [>=1]
discount    M =0 [>=0, <=1]
type        s32 ['standard','express','bulk']

-> user_id -> user.id [CASCADE]
