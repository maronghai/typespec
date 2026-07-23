$ testdb

# users

id    n++
name  s32

# orders

id      n++
user_id n

> user_id users.nonexistent_field
