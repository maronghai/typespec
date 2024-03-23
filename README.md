# typespec

1. Number
    - `\d+` -> int
        - int(n)
    - `n` -> int
    - `N` -> bigint
    - `\d+,\d+` -> float or double
        - decimal(m, n)
2. Money
    - `m` -> money
        - decimal(16, 2)
    - `M` -> money plus
        - decimal(20, 6)
3. String
    - `s` -> string
    - `S` -> text
4. datetime
    - `t` -> datetime
