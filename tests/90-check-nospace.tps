; ── Test 90: CHECK constraints with no-space comma ──
$ demo

# constrained
id      n++
age     n [0,150]
amount  m {>0}
ratio   M {>=0,<=100}
type    s16 ['a','b','c']
