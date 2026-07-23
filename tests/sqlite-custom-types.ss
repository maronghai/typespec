; SQLite: custom type definitions with ~ directive
$ demo

~ money 16,2
~ email s128

# accounts
id       n++
balance  money *
contact  email *
name     s32 *
