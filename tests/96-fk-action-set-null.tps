; ── Test 96: FK action — delete set null + update cascade ──
$ demo

# user
id   n++
name s32 *

# coupon
id   n++

# order
id        n++
user_id   n
coupon_id n
amount    m

> user_id user.id -C C
> coupon_id coupon.id -N C
