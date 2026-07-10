; ── Test 97: FK action — inline FK with actions ──
$ demo

# user
id   n++
name s32 *

# order
id        n++
user_id   n > user.id -C C
amount    m
