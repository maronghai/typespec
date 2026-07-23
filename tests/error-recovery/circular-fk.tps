$ testdb

# employees

id         n++
name       s32
dept_id    n

> dept_id departments.id

# departments

id         n++
name       s32
lead_id    n

> lead_id employees.id
