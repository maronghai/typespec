; ══════════════════════════════════════════════════════════════
; Complex E-Commerce + SaaS Platform Schema
; ══════════════════════════════════════════════════════════════
; Features demonstrated:
;   - 3-level template inheritance (base → audit → soft_delete)
;   - Default template for implicit tables
;   - All type symbols: n, N, m, M, s, S, b, B, j, d, t
;   - Suffix inference: _id, _on, _at
;   - FK actions: CASCADE, SET NULL, NO ACTION, RESTRICT, UPDATE
;   - CHECK constraints: range, IN, comparison
;   - Composite primary keys
;   - Composite unique indexes
;   - Fulltext index
;   - Three comment styles: ;, --, //
;   - Field modifiers: ++, +, *, =, !
; ══════════════════════════════════════════════════════════════

$ ecommerce

; ──────────────────────────────────────────────────────────────
; Template Definitions
; ──────────────────────────────────────────────────────────────

; ── Base: universal audit fields ──
% base
id n++
...
version   N
status    1 =0
create_at t+
update_at t++

; ── Audit: extends base, adds soft-delete tracking ──
% audit extends base
...
deleted_at t
deleted_by n

; ── Soft Delete: extends audit, adds restore capability ──
% soft_delete extends audit
...
restore_token s64
restore_expires_on d

; ── Default template (unnamed) for ad-hoc tables ──
%
id n++
...
created_at t+

; ──────────────────────────────────────────────────────────────
; User Domain
; ──────────────────────────────────────────────────────────────

#soft_delete user  // 用户表

name        s32 *
email       s128 *
password    s256 *
phone       s20
avatar      S
bio         s512
is_verified b =0
is_admin    b =0
role        1 =0 [0,1,2,3]
balance     m =0
settings    j

@! uk_email (email)
@ idx_name (name)
@ idx_phone (phone)

; ── User Address ──
#soft_delete user_address  // 用户地址

user_id           ; suffix _id → int
label     s16 =''     -- e.g. 'home', 'office'
province  s32
city      s32
district  s32
address   s256 *
zip       s10
phone     s20
is_default b =0

-> user_id -> user.id [CASCADE, UPDATE CASCADE]

@ idx_user (user_id)
@ idx_default (user_id, is_default)

; ── User OAuth ──
#audit user_oauth  // 第三方登录

user_id           ; -> user.id
provider  s32 *    -- 'github', 'google', 'wechat'
open_id   s128 *
access_token  S
refresh_token S
expires_on    t

-> user_id -> user.id [CASCADE]
; NOTE: composite FKs (e.g. -> (a, b) -> t.id) are not supported by the grammar.
;       Use multiple single-column FKs or ALTER TABLE in SQL.

@! uk_provider_open (provider, open_id)
@ idx_user (user_id)

; ──────────────────────────────────────────────────────────────; Product Domain
; ──────────────────────────────────────────────────────────────

; ── Category (self-referencing tree) ──
#base category  // 商品分类

name      s64 *
parent_id         ; self-ref, nullable root
sort_order n =0
icon      s128
is_active b =1

-> parent_id -> category.id [SET NULL]
@ idx_parent (parent_id)
@ idx_sort (sort_order)

; ── Brand ──
#soft_delete brand  // 品牌

name      s64 *
logo      s256
description S
website   s256
is_active b =1

@! uk_name (name)

; ── Product ──
#soft_delete product  // 商品表

name      s128 *
subtitle  s256
brand_id          -- -> brand.id
category_id       -- -> category.id
price     m * [>0]
market_price m =0
cost_price  m =0
stock     n =0 [>=0]
sales     N =0
weight    M =0
rating    4,2 =0        ; explicit decimal: decimal(4,2)
raw_data  B             ; binary attachment (blob)
is_on_sale b =1
sort_order n =0
main_image s256
images    j
attributes j

-> brand_id -> brand.id [SET NULL]
-> category_id -> category.id [SET NULL]

@ idx_category (category_id)
@ idx_brand (brand_id)
@ idx_price (price)
@ idx_sales (sales)
@ idx_sale_status (is_on_sale, sort_order)

; ── Product SKU ──
#audit product_sku  // 商品 SKU

product_id         ; -> product.id
sku_code   s64 *
spec_name  s128 *    -- e.g. "红色 / XL"
price      m * [>0]
stock      n =0 [>=0]
image      s256
sort_order n =0

-> product_id -> product.id [CASCADE]

@! uk_sku_code (sku_code)
@ idx_product (product_id)

; ── Product Review ──
#soft_delete product_review  // 商品评价

product_id         ; -> product.id
user_id            -- -> user.id
order_id           -- -> order.id
rating     1 * [1,2,3,4,5]
title      s128
content    S
images     j
is_anonymous b =0
reply      S
replied_on t

-> product_id -> product.id [CASCADE]
-> user_id -> user.id [CASCADE]

@ idx_product (product_id)
@ idx_user (user_id)
@ idx_rating (rating)

; ──────────────────────────────────────────────────────────────
; Order Domain
; ──────────────────────────────────────────────────────────────

; ── Coupon Template ──
% coupon_base extends base
...
type        1 =0 [0,1,2]     -- 0=fixed, 1=percent, 2=free_shipping
min_amount  m =0
discount    m =0
max_discount m =0
start_on    d
end_on      d

; ── Coupon ──
#coupon_base coupon  // 优惠券

name      s64 *
code      s64 *
total     n =0
used      n =0
per_user  n =1
is_active b =1

@! uk_code (code)

; ── Order ──
#soft_delete order  // 订单表

order_no   s64 *
user_id           -- -> user.id
coupon_id         -- -> coupon.id (nullable)
status     1 =0 [0,1,2,3,4,5]  -- 0=pending, 1=paid, 2=shipped, 3=completed, 4=cancelled, 5=refunded
total      m * [>0]
discount   m =0
shipping   m =0
actual     m * [>0]
payment_method s32
payment_no s128
note       s512
paid_on    t
shipped_on t
completed_on t

-> user_id -> user.id [NO ACTION]
-> coupon_id -> coupon.id [SET NULL]

@! uk_order_no (order_no)
@ idx_user (user_id)
@ idx_status (status)
@ idx_paid (paid_on)
@ idx_created (create_at)

; ── Order Item ──
#audit order_item  // 订单商品

order_id           -- -> order.id
product_id         -- -> product.id
sku_id             -- -> product_sku.id
product_name s128 *   -- snapshot
sku_name     s128 *   -- snapshot
price        m *
quantity     n * [>=1]
subtotal     m *
image        s256

-> order_id -> order.id [CASCADE]
-> product_id -> product.id [NO ACTION]
-> sku_id -> product_sku.id [SET NULL]

@ idx_order (order_id)

; ── Shipping ──
#audit shipping  // 物流信息

order_id           -- -> order.id
carrier     s32 *    -- 'SF', 'ZTO', 'YTO'
tracking_no s64 *
status      1 =0 [0,1,2,3]
shipped_on  t
delivered_on t

-> order_id -> order.id [CASCADE]

@! uk_tracking (carrier, tracking_no)
@ idx_order (order_id)

; ──────────────────────────────────────────────────────────────
; Payment Domain
; ──────────────────────────────────────────────────────────────

#audit payment  // 支付记录

order_id           -- -> order.id
user_id            -- -> user.id
method     s32 *    -- 'alipay', 'wechat', 'card'
amount     m * [>0]
trade_no   s128
status     1 =0 [0,1,2,3]  -- 0=pending, 1=success, 2=failed, 3=refunded
paid_on    t
extra      j

-> order_id -> order.id [RESTRICT]
-> user_id -> user.id [NO ACTION]

@ idx_order (order_id)
@ idx_user (user_id)
@ idx_trade (trade_no)

; ──────────────────────────────────────────────────────────────
; Content Domain (CMS)
; ──────────────────────────────────────────────────────────────

#base article  // 文章/帮助中心

title     s256 *
slug      s128 *
content   S *         -- long-form HTML
summary   s512
cover     s256
category  s32 =''    -- 'help', 'faq', 'changelog'
tags      j
views     N =0
is_published b =0
published_on t

@! uk_slug (slug)
@ idx_category (category)
@ idx_published (is_published, published_on)
@f ft_content (title, content)

; ── Banner / Ad ──
#base banner  // 轮播图

title     s64 *
image     s256 *
link      s512
position  s32 =''    -- 'home', 'list', 'detail'
sort_order n =0
is_active b =1
start_on  d
end_on    d

@ idx_position (position, is_active)

; ──────────────────────────────────────────────────────────────
; Notification Domain
; ──────────────────────────────────────────────────────────────

#audit notification  // 站内消息

user_id            -- -> user.id
type      s32 *     -- 'order', 'system', 'promo'
title     s128 *
content   S
is_read   b =0
link      s512
extra     j

-> user_id -> user.id [CASCADE]

@ idx_user_read (user_id, is_read)
@ idx_type (type)

; ──────────────────────────────────────────────────────────────
; System / Config Domain
; ──────────────────────────────────────────────────────────────

# setting  // 系统配置

key       s128 *
value     S
category  s32 =''    -- 'basic', 'payment', 'shipping'
updated_on t++

@! uk_key (key)
@ idx_category (category)

; ── Operation Log ──
% log_base
id N++
...
operator_id   n
operator_name s32
action   s32 *
target   s32
target_id N
detail   j
ip       s64

#log_base op_log  // 操作日志

@ idx_operator (operator_id)
@ idx_action (action)
@ idx_target (target, target_id)

; ──────────────────────────────────────────────────────────────
; Composite Primary Key Example
; ──────────────────────────────────────────────────────────────

; ── User Role (many-to-many) ──
# user_role  // 用户角色关联

user_id n!
role_id n!

@ idx_role (role_id)

; ── Product Tag (many-to-many) ──
# product_tag  // 商品标签关联

product_id n!
tag_id     n!

-> product_id -> product.id [CASCADE]
-> tag_id -> tag.id [NO ACTION]

@ idx_tag (tag_id)

; ── Tag ──
#base tag  // 标签

name     s32 *
color    s7 =''     -- hex color: '#FF5722'
usage_count n =0

@! uk_name (name)
