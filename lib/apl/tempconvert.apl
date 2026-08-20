⍝ a vector of Fahrenheit temperatures converted to Celsius all at once:
⍝ (F-32)×5÷9 - parentheses matter here despite the right-to-left rule,
⍝ since without them 5÷9 would apply to 32 first, not to (F-32)
F←32 50 68 86 104
(F-32)×5÷9
