# `orders`
id bigint ++ *
user_id int * @
total 16, 2 *
status enum('pending','paid','shipped','done') * =pending
created_at datetime * =CURRENT_TIMESTAMP 

@ user_id
> user_id users.id