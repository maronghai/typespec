# Type Spec

1. Number
    - `\d+` -> int
        - int(n)
    - `n` -> int
    - `N` -> bigint
    - `\d+` `,` `\d+` -> float or double
        - decimal(m, n)
2. Money
    - `m` -> money
        - decimal(16, 2)
    - `M` -> money plus
        - decimal(20, 6)
3. String
    - `s` -> varchar
        - `s` `\d+` -> varchar(n)
    - `S` -> text
4. datetime
    - `t` -> datetime


## Ecosystem

1. [DB Spec](https://github.com/maronghai/dbspec)

## License

[MIT](https://opensource.org/licenses/MIT)

Copyright (c) 2023-present, Ronghai Ma
