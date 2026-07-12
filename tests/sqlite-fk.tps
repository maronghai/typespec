; SQLite: foreign key with actions
$ demo

# order
id        n++
user_id   n *
amount    m *
created   t

> user_id user.id on delete cascade on update set null
