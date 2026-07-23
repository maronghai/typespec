$ testdb utf8mb4

% base
  id n++
  created_at t+
  updated_at t+
  deleted_at t
  ...

# user > base
  name s64 *
  email s128 * @u
  password_hash s255 *
  role s16 *
  is_active b *
  last_login_at t

# post > base
  title s200 *
  slug s200 * @u
  body S *
  status s16 *
  published_at t

# comment > base
  post_id n *
  user_id n *
  body S *

# tag
  name s64 * @u
  slug s64 * @u

# post_tag
  post_id n *
  tag_id n *
