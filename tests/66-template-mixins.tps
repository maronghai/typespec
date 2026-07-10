; ── Test 66: Template mixins ──
$ demo

% base
id n++
version N

% soft_delete
deleted_at t
deleted_by n

% user_mixin base + soft_delete
name s32 *
email s128 *

# user_mixin user
phone s16
