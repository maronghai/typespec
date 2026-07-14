; SQLite: mixed features — enum CHECK, template, autofk, composite PK
$ demo autofk

% base
id n++
...

# base user
name    s32 *
status  e(active,inactive) *

# base order
order_no  s64 *
user_id   n
amount    m

# user_role
user_id n ! *
role_id n ! *
assigned t
