$ testdb

% base_template
...
id   n++
name s32 *

# valid_after_bad_template

id   n++
email s

% >> invalid_syntax
...
data s

# another_valid_table

id   n++
status s10 *
