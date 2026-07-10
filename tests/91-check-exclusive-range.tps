; ── Test 91: CHECK exclusive range ──
$ demo

# user
id   n++

age_upper    n =0 [0,150)    ; CHECK (age_upper >= 0 AND age_upper < 150)
age_lower    n =0 (0,150]    ; CHECK (age_lower > 0 AND age_lower <= 150)
age_both     n =0 (0,150)    ; CHECK (age_both > 0 AND age_both < 150)
