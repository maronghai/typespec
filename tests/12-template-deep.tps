; ── Test 12: Template inheritance (3-level) ──
$ demo

% base
id n++
...
version N
status 1 =0

% audit > base
...
create_at t+
update_at t++

% soft_delete > audit
...
deleted_at t
deleted_by n

# soft_delete user
name s32 *
email s128 *
