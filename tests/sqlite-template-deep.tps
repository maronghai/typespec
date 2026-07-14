; SQLite: deep template inheritance (3 levels)
$ demo

% base
id n++
...

% mid > base
created t
...

#base mid user
name s32 *

#base mid order
amount m
