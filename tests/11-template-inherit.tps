; ── Test 11: Template inheritance (2-level) ──
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

# audit user
name s32 *
email s128 *
