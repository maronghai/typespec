$ enterprisedb utf8mb4

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

% soft_delete > base
  ...

# tenant > audited
  name s100 *
  slug s100 * @u
  domain s255
  plan s32 *
  max_seats n *
  is_active b *
  settings j

# user > audited
  tenant_id n *
  email s128 * @u
  password_hash s255 *
  first_name s64 *
  last_name s64 *
  display_name s128
  avatar_url s512
  role s32 *
  is_active b *
  last_login_at t
  login_count n
  mfa_enabled b
  mfa_secret s128

# role
  tenant_id n *
  name s64 *
  description S
  permissions j *
  is_system b *

# user_role
  user_id n *
  role_id n *

# team > audited
  tenant_id n *
  name s64 *
  description S
  parent_team_id n

# team_member
  team_id n *
  user_id n *
  role s32 *

# project > audited
  tenant_id n *
  name s100 *
  slug s100 * @u
  description S
  status s32 *
  owner_id n *
  start_date d
  end_date d
  budget m

# project_member
  project_id n *
  user_id n *
  role s32 *

# task > audited
  project_id n *
  title s200 *
  description S
  status s32 *
  priority n *
  assignee_id n
  reporter_id n *
  parent_task_id n
  estimate_hours m
  logged_hours m
  due_date d
  labels s255
  sprint_id n

# sprint > audited
  project_id n *
  name s64 *
  goal S
  start_date d *
  end_date d *
  status s32 *

# epic > audited
  project_id n *
  title s200 *
  description S
  status s32 *
  color s7

# story > audited
  epic_id n *
  title s200 *
  description S
  status s32 *
  priority n *
  story_points n
  assignee_id n

# bug > audited
  project_id n *
  title s200 *
  description S *
  status s32 *
  severity n *
  priority n *
  assignee_id n
  reporter_id n *
  steps_to_reproduce S
  environment s255
  version s32

# comment > audited
  task_id n
  story_id n
  bug_id n
  user_id n *
  body S *
  parent_id n

# attachment > audited
  task_id n
  story_id n
  bug_id n
  filename s255 *
  url s512 *
  mime_type s128 *
  size_bytes n

# time_entry > audited
  task_id n
  story_id n
  user_id n *
  hours m *
  description S
  date d *

# label
  tenant_id n *
  name s64 *
  color s7 *

# task_label
  task_id n *
  label_id n *

# notification
  user_id n *
  type s64 *
  title s200 *
  body S
  read_at t
  link s512
  metadata j

# audit_log
  tenant_id n *
  user_id n
  action s64 *
  resource_type s64 *
  resource_id n
  old_values j
  new_values j
  ip_address s45
  user_agent s512
  created_at t *

# webhook > audited
  tenant_id n *
  url s512 *
  secret s255 *
  events s255 *
  is_active b *
  last_triggered_at t
  failure_count n

# api_key > audited
  user_id n *
  name s64 *
  key_hash s255 *
  scopes s255
  last_used_at t
  expires_at t
  is_active b *

# setting
  tenant_id n *
  key s128 *
  value S
  category s64

# integration > audited
  tenant_id n *
  type s64 *
  name s64 *
  config j *
  is_active b *

# export_job > audited
  tenant_id n *
  user_id n *
  type s64 *
  status s32 *
  file_url s512
  started_at t
  completed_at t
  error_message S
