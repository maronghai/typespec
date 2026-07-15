# inventory
id n ++
product_id *
quantity n * =0 -- [LOW]
location : Warehouse location
updated_at =(datetime('now'))

@ idx_product (product_id)
> product_id products.id