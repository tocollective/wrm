// Offsets past imm14 (7.8) where the value also needs a scratch register:
// an unaligned field of a packed struct 9KB into it, and small copies 9KB
// into structs. The address goes through r9, the value must not.
// @output "far 305419896 120 7,8,9 7,8,9\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { putd, say, nl } from "lib/print.m"

packed type Far {
    pad:  UByte[9001],
    x:    UWord,            // offset 9001: unaligned and far
    tail: UByte,
}

type Rgb {
    r: UByte,
    g: UByte,
    b: UByte,
}

type Deep {
    pad: UByte[9000],
    c:   Rgb,               // offset 9000: far, copied with byte loads
}

let mut far: Far
let mut one: Deep
let mut two: Deep

let showRgb(c: Rgb): Void {
    puts(" ")
    putd(c.r as Word)
    puts(",")
    putd(c.g as Word)
    puts(",")
    putd(c.b as Word)
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("far")
    far.x = 0x1234_5678
    say(far.x as Word)
    far.tail = 120
    say(far.tail as Word)
    one.c = { .r = 7, .g = 8, .b = 9 }
    two.c = one.c
    showRgb(two.c)
    let mut local: Deep = {}
    local.c = two.c
    showRgb(local.c)
    nl()
    return 0
}
