// Syntax error: missing commas in a struct literal over lines (init.m)
// @error 7: missing ',' before '.g'

type Color { r: UByte, g: UByte, b: UByte }
let C: Color = {
    .r = 0x00
    .g = 0x00
}
