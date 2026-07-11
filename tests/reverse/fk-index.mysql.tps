# `user`
id int ++ *
name s128 *
email

# `order`
id int ++ *
order_no s64 *
user_id int @
amount 16, 2 *

> user_id user.id