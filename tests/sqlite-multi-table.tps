; SQLite: multiple tables with FKs
$ shop

# customer
id    n++
name  s *
email s128 *

@u email

# product
id    n++
name  s *
price m *

# order_item
id         n++
customer_id n
product_id  n
quantity    n *
