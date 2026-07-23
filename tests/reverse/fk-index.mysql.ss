# user
id n ++ *
name s128 *
email

# order
id n ++ *
order_no s64 *
user_id @
amount m *

> user_id user.id