// A ROM image (m.py --rom, rom0.asm): .data is copied from ROM to RAM and
// can be changed there, .bss is zeroed, constants stay in ROM.
// @rom
// @output "rom 7 255 1 0 hi 8 256 1 5\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, nl } from "lib/print.m"

type Pair {
    a: UByte,
    b: UHalf,
}

let mut counter: Word = 7
let mut pair: Pair = { .a = 0xFF, .b = 1 }
let mut zeros: UWord[100]
let mut text: *UByte = "hi"
let LIMIT: Word = 5

let main(argc: UWord, argv: *UByte[]): Word {
    puts("rom")
    say(counter)
    say(pair.a as Word)
    say(pair.b as Word)
    say(zeros[99] as Word)
    puts(" ")
    puts(text)
    counter++
    pair.a = 0
    pair.b = pair.b + 255
    say(counter)
    say((pair.a as Word) + (pair.b as Word))
    say((&counter as UWord < 0xFE00_0000) as Word)   // in RAM, not in ROM
    say(LIMIT)
    nl()
    return 0
}
