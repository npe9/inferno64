10 REM ask for a name and greet it, using a GOSUB subroutine
20 INPUT "What is your name? "; N$
30 GOSUB 100
40 PRINT "Your name has "; LEN(N$); " letters."
50 END
100 REM subroutine: print a greeting for N$
110 PRINT "Hello, "; N$; "!"
120 RETURN
