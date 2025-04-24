# Type Spec

## 1. Introduction

This project provides a mapping between specific symbols or regular expressions and corresponding data types. This mapping is intended to be used for parsing and converting data in various scenarios, such as databases, data analysis, and programming language parsing.

## 2. Specification

The mapping is defined as follows:

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
        - `s` `/` `\d+` -> varchar(n)
            - `s1` = `s/32` -> varchar(32)
            - `s2` = `s/64` -> varchar(64)
            - `s3` = `s/128`-> varchar(128)
            - `s4` = `s/256`-> varchar(256)
            - `s5` = `s/512` -> varchar(512)
            - `s6` = `s/1024` -> varchar(1024)
            - `s7` = `s/2048` -> varchar(2048)
    - `S` -> text
    - `DEFAULT` -> s
4. Date & Datetime
    - `d` -> date
    - `t` -> datetime
5. Suffix
    - `_id` -> int
    - `_on` -> date
    - `_at` -> datetime

## 3. Usage

```asm
id        n       ; int
group_id  n       ; int
type      1       ; int(1)

name              ; Default type is 's'
pin       s/100   ; varchar(100)
avatar    S       ; text

balance   m       ; decimal(16, 2)
version   N       ; bigint

vip_on    d       ; date
delete_on         ; date
create_at t       ; datetime
update_at         ; datetime

```

## 4. Regex Expression

> This multi-line regular expression is described using the [ZZ](https://github.com/maronghai/zz)

```asm
n             ; int
|N            ; bigint

|m            ; decimal(16, 2)
|M            ; decimal(20, 6)

|\d+          ; int(n)
|\d+,\d+      ; decimal(m, n)

|s/(?:\d+)?   ; varchar(n)
|s(?:\d+)?    ; varchar(2^(n+5))
|S            ; text
|t            ; datetime
```

```asm
\b(?:[nNmMSt]|s(?:/)?(?:\d+)?|\d+(?:,\d+)?)\b
```

## 5. Ecosystem

1. [DB Spec](https://github.com/maronghai/dbspec)
2. [ZZ](https://github.com/maronghai/zz)

## 6. License

[MIT](https://opensource.org/licenses/MIT)

Copyright (c) 2023-present, Ronghai Ma
