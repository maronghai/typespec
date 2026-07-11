$ demo

% base
id n++
...
status    1 =0
create_at +

#base user  : 用户表

name      s32 *
email     s128 *
balance   m =0

@u email

#base order  : 订单表

order_no    s64 *
user_id               : 下单用户
amount      m *

> user_id user.id
