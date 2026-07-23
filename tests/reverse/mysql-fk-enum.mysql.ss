# orders
id N ++ *
user_id *
total m *
status enum('pending','paid','shipped','done') * =pending
created_at * =CURRENT_TIMESTAMP 

@ idx_user (user_id)
> user_id users.id