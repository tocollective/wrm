// Imports: only by name, there is no 'import *'.
//
// The path in 'from' is looked up:
//   1. relative to the directory of this file;
//   2. then in each directory given to the compiler with '-I', in order.

import { puts } from "../externs.m"
import { Color, colorRed, mix } from "color.m"

// The same file can be imported more than once. 'as' renames locally.
import { colorGreen as green } from "color.m"

// Compile error: 'colorMake' is not exported from color.m
//     import { colorMake } from "color.m"

// 'main' is exported automatically, so crt0 can call it: no 'export { main }'.
let main(argc: UWord, argv: *UByte[]): Word {
    let red: Color = colorRed()
    let yellow: Color = mix(red, green())

    if yellow.r == 0xFF puts("yellow has red\n")
    return 0
}

// Test directives (m/tests/run.py)
// @output "yellow has red\n"
// @exit 0
