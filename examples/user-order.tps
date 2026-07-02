; ── User-Order Example ──
; Demonstrates templates, foreign keys, and indexes

$ ecommerce

; ── Base Template ──
% base
id n++
...
version   N
status    1 =0
delete_at t
create_at t+
update_at t++

; ── User Table ──
#base user  // 用户表

name      s32 *
email     s128 *
password  s256 *
avatar    S
is_admin  b =0
balance   m =0
settings  j

@u email
@ name

; ── Product Table ──
#base product  // 商品表

name        s128 *
description S
price       m *
stock       n =0
category_id         ; suffix _id → int

@ category_id
@ price

; ── Order Table ──
#base order  // 订单表

order_no    s64 *
user_id             ; suffix _id → int
amount      m *
discount    M =0
note        s512
paid_on     d

-> user_id user.id [CASCADE]

@u order_no
@ user_id
@ paid_on
