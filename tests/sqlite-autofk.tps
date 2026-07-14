; SQLite: autofk inference from _id suffix
$ demo autofk

# user
id    n++
name  s32 *

# order
id        n++
order_no  s64 *
user_id   n
amount    m
