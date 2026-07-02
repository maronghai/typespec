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

name      s32 *     // 用户登录名
email     s128 *    // 唯一邮箱
password  s256 *    // bcrypt hash
avatar    S         // 头像 URL，可为空
is_admin  b =0      // 管理员标记
balance   m =0      // 账户余额（分）
settings  j         // JSON 用户偏好

@u email
@ name

; ── Product Table ──
#base product  // 商品表

name        s128 *      // 商品名称
description S           // 商品详情（富文本）
price       m *         // 单价（分）
stock       n =0        // 库存数量
category_id             // 分类 ID（suffix _id → int）

@ category_id
@ price

; ── Order Table ──
#base order  // 订单表

order_no    s64 *       // 唯一订单号
user_id                 // 下单用户（suffix _id → int）
amount      m *         // 订单总额（分）
discount    M =0        // 折扣金额（分）
note        s512        // 买家留言
paid_on     d           // 支付日期

-> user_id user.id [CASCADE]

@u order_no
@ user_id
@ paid_on
