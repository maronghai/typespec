# Type Spec

## 1. Introduction

This project provides a mapping between specific symbols or regular expressions and corresponding data types. This mapping is intended to be used for parsing and converting data in various scenarios, such as databases, data analysis, and programming language parsing.

## 2. Specification

The mapping is defined as follows:

- `n`: corresponds to the `int` type.
- `N`: corresponds to the `bigint` type.
- `m`: corresponds to the `decimal(16, 2)` type.
- `M`: corresponds to the `decimal(20, 6)` type.
- `\d+`: corresponds to the `int(n)` type, where `n` is a number.
- `\d+,\d+`: corresponds to the `decimal(m, n)` type, where `m` and `n` are numbers.
- `s(?:\d+)?`: corresponds to the `varchar(n)` type, where `n` is an optional number.
- `S`: corresponds to the `text` type.
- `t`: corresponds to the `datetime` type.

1. Number
    - `\d+` -> int(n)
    - `n` -> int
    - `N` -> bigint
    - `\d+` `,` `\d+` -> decimal(m, n)
2. Money
    - `m` -> decimal(16, 2)
    - `M` -> decimal(20, 6)
3. String
    - `s` -> varchar
        - `s` `\d+` -> varchar(n)
    - `S` -> text
4. datetime
    - `t` -> datetime

## 3. Usage

```
id n
name s
avatar S

balance m
version N
create_at t
```

## 4. Regex Expression

> This multi-line regular expression is described using the [ZZ](https://github.com/maronghai/zz)

```asm
n            ; int
|N           ; bigint

|m           ; decimal(16, 2)
|M           ; decimal(20, 6)

|\d+         ; int(n)
|\d+,\d+     ; decimal(m, n)

|s(?:\d+)?   ; varchar(n)
|S           ; text
|t           ; datetime
```

```asm
\b(?:[nNmMSt]|s(?:\d+)?|\d+(?:,\d+)?)\b
```

## 5. Ecosystem

1. [DB Spec](https://github.com/maronghai/dbspec)
2. [ZZ](https://github.com/maronghai/zz)

## 6. License

[MIT](https://opensource.org/licenses/MIT)

Copyright (c) 2023-present, Ronghai Ma
