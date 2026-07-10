; ── Test 93: CHECK brace comparison ──
$ demo

# user
id   n++

amount    m {>0}               ; CHECK (amount > 0)
ratio     M {>=0,<=100}       ; CHECK (ratio >= 0 AND ratio <= 100)
score     n {>=0}             ; CHECK (score >= 0)
