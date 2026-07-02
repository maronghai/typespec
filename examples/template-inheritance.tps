; ── Template Inheritance Example ──
; Shows how templates extend other templates

$ demo

; ── Base Template ──
% base
id n++
...
version   N
status    1 =0
create_at t+
update_at t++

; ── Audit Template (extends base) ──
% audit extends base
...
deleted_at t
deleted_by n

; ── Soft Delete Template (extends audit) ──
% soft_delete extends audit
...
restore_token s64

; ── User Table (uses soft_delete) ──
#soft_delete user  // 用户表

name      s32 *
email     s128 *

; ── Order Table (uses audit) ──
#audit order  // 订单表

order_no  s64 *
amount    m *
