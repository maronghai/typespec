# `order_status`
id int ++
status enum('pending', 'confirmed', 'shipped', 'delivered') *
priority enum('low', 'medium', 'high') =medium
name s100 *
