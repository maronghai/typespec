; ── Test 21: Composite index ──
$ demo

# multi
id     n++
name   s32
email  s128
status 1

@ idx_name_email (name, email)
@u uk_email_status (email, status)
