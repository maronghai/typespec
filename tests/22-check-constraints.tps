; ── Test 22: CHECK constraints — all forms ──
$ demo

# constrained
id      n++
age     n [0,150]
score   m [0,100]
amount  m {>0}
qty     n {>=1}
type    s16 {a,b,c}
range2  n {>=0,<=100}
