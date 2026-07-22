$ appdb utf8mb4

% base
  id n++
  created_at t+
  updated_at t+
  deleted_at t
  ...

% audited > base
  created_by n
  updated_by n
  ...

# user > audited
  username s64 *
  email s128 * @u
  password_hash s255 *
  display_name s128
  avatar_url s512
  role s16 *
  is_active b *
  last_login_at t
  login_count n

# organization > audited
  name s100 *
  slug s100 * @u
  description S
  plan s32 *
  max_users n *

# project > audited
  org_id n *
  name s100 *
  slug s100 * @u
  description S
  visibility s16 *
  repo_url s512

# team > audited
  org_id n *
  name s64 *
  description S

# team_member
  team_id n *
  user_id n *
  role s32 *

# issue > audited
  project_id n *
  title s200 *
  body S
  status s32 *
  priority n *
  assignee_id n
  labels s255
  milestone_id n

# milestone > audited
  project_id n *
  name s100 *
  description S
  due_date d
  status s32 *

# pull_request > audited
  project_id n *
  title s200 *
  body S
  source_branch s100 *
  target_branch s100 *
  status s32 *
  merged_at t
  reviewer_id n

# review > audited
  pr_id n *
  user_id n *
  status s32 *
  body S

# comment > audited
  issue_id n
  pr_id n
  user_id n *
  body S *
  parent_id n

# label
  org_id n *
  name s64 *
  color s7 *

# issue_label
  issue_id n *
  label_id n *

# attachment > audited
  issue_id n
  pr_id n
  filename s255 *
  url s512 *
  mime_type s128 *
  size_bytes n

# webhook > audited
  org_id n *
  url s512 *
  secret s255 *
  events s255 *
  is_active b *

# api_key > audited
  user_id n *
  name s64 *
  key_hash s255 *
  last_used_at t
  expires_at t

# audit_log
  org_id n *
  user_id n
  action s64 *
  resource_type s64 *
  resource_id n
  metadata j
  ip_address s45
  created_at t *

# notification
  user_id n *
  type s64 *
  title s200 *
  body S
  read_at t
  link s512

# settings
  org_id n *
  key s128 *
  value S
