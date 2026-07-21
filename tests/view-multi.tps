$ demo

# user
id   n++
name s32 *

# order
id      n++
user_id n
amount  m

& user_summary = SELECT u.id, u.name, COUNT(o.id) AS order_count FROM user u LEFT JOIN order o ON u.id = o.user_id GROUP BY u.id
& expensive_orders = SELECT * FROM order WHERE amount > 1000
