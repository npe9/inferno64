decl 10:1 Level type Level
decl 13:2 Low const Level
decl 14:2 High const Level
decl 17:1 Point type Point
decl 22:1 Shape type Shape
decl 36:1 dist func fn(Point): int
decl 44:1 size func fn(ref Shape): int
decl 54:1 init func fn(ref Context, list of string)
decl 29:1 name method fn(Level): string
in Level.name
decl 29:7 l arg Level
use 30:5 l 29:7 Level
use 30:10 Low 13:2 Level
in dist
decl 37:2 d local int
use 37:2 d 37:2 int
decl 36:11 p arg Point
use 37:7 p 36:11 Point
decl 27:5 origin global Point
use 37:13 origin 27:5 Point
use 38:5 d 37:2 int
use 39:3 d 37:2 int
use 39:8 d 37:2 int
use 41:9 d 37:2 int
use 41:13 p 36:11 Point
in size
decl 44:11 s arg ref Shape
use 45:8 s 44:11 ref Shape
decl 48:18 n local int
use 48:18 n 48:18 int
use 49:10 n 48:18 int
in init
use 55:2 origin 27:5 Point
use 55:11 Point 17:1 Point
decl 56:2 p local Point
use 56:2 p 56:2 Point
use 56:7 Point 17:1 Point
decl 7:1 sys global Sys
use 57:2 sys 7:1 Sys
decl Sys:119:1 print func fn(string): int
use 57:6 print Sys:119:1 fn(string): int
use 57:26 name 29:1 fn(Level): string
use 57:26 High 14:2 Level
use 57:39 dist 36:1 fn(Point): int
use 57:44 p 56:2 Point
use 57:48 size 44:1 fn(ref Shape): int
