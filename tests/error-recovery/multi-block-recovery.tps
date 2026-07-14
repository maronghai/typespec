$ testdb

# valid_table

id   n++
name s32 *

# table_with_bad_field

id   n++
bad_field @invalid_syntax_here
name s32 *

# another_valid_table

id   n++
email s u

# table_with_duplicate_fields

id   n++
name s32 *
name s64 *
