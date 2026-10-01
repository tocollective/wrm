// Syntax error: missing commas in a struct literal (init.m)
// @error 5: missing ',' before '.g'

type Color { r: UByte, g: UByte, b: UByte }
let C: Color = { .r = 0x00 .g = 0x00 .b = 0xFF }
