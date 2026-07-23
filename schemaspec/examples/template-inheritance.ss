; ── Template Inheritance Example ──
; Shows how templates extend other templates

$ demo

; ── Base Template ──
% base
id n++
...
version   N
status    1 =0
create_at +
update_at ++

; ── Audit Template (> base) ──
% audit > base
...
deleted_at
deleted_by n

; ── Soft Delete Template (> audit) ──
% soft_delete > audit
...
restore_token s64

; ── User Table (uses soft_delete) ──
#soft_delete user  : 用户表

name      s32 *
email     s128 *

; ── Order Table (uses audit) ──
#audit order  : 订单表

order_no  s64 *
amount    m *
