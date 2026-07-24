; old: with FK
$ demo

# user
id    n++

# order
id        n++
user_id   n *
amount    m *

> user_id user.id
