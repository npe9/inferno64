decl 10:1 Named type ref .Named$s
decl 14:1 Tag type Tag
decl 20:1 first func nil
decl 24:1 label func fn(ref .Named$s): string
decl 28:1 adder func fn(int): func(int): int
decl 34:1 init func fn(ref Context, list of string)
decl 16:1 name method fn(Tag): string
in Tag.name
decl 16:7 t arg Tag
use 17:16 t 16:7 Tag
in label
decl 24:12 n arg ref .Named$s
use 25:15 n 24:12 ref .Named$s
in adder
decl 28:12 base arg int
use 28:1 base 28:12 int
in init
decl 35:2 t local Tag
use 35:2 t 35:2 Tag
use 35:2 t 35:2 Tag
decl 36:2 f local func(int): int
use 36:2 f 36:2 func(int): int
use 36:7 adder 28:1 fn(int): func(int): int
decl 37:2 g local func(): string
use 37:2 g 37:2 func(): string
decl 7:1 sys global Sys
use 38:2 sys 7:1 Sys
decl Sys:119:1 print func fn(string): int
use 38:6 print Sys:119:1 fn(string): int
decl 38:29 first[string] func fn(list of string): string
use 38:29 first[string] 38:29 fn(list of string): string
use 38:49 nil - polymorphic type
use 38:55 label 24:1 fn(ref .Named$s): string
use 38:65 f 36:2 func(int): int
use 38:71 g 37:2 func(): string
in first[string]
decl 20:15 l arg list of string
use 21:12 l 20:15 list of string
