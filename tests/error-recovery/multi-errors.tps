$ mydb

# user

id      n++
name    s32 ++
email   s
balance m +

# order

order_no    s64 *
user_id     > nonexistent.id
amount      m
