10 REM classic fizzbuzz, 1 to 20
20 FOR I = 1 TO 20
30 LET A$ = ""
40 IF I MOD 3 = 0 THEN LET A$ = A$ + "Fizz"
50 IF I MOD 5 = 0 THEN LET A$ = A$ + "Buzz"
60 IF A$ = "" THEN LET A$ = STR$(I)
70 PRINT A$
80 NEXT I
90 END
