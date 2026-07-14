; SQLite: FK actions (ON DELETE/UPDATE)
$ demo

# user
id   n++
name s32 *

# order
id      n++
user_id n
amount  m

> user_id user.id -C

# log
id       n++
order_id n

> order_id order.id -N
