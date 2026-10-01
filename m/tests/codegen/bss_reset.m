// crt0 zeroes .bss: RAM keeps its contents over a reset (SPECIFICATION,
// "Memory"), so the first boot dirties a .bss variable and resets, and
// the second boot finds it zero again.
// @output "reset\nbss 0\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { putu } from "lib/print.m"

let mut dirty: UWord[4]

// A word far above the image and below the end of 1MB of RAM; neither the
// firmware nor this program uses it otherwise.
let marker: *mut UWord = 0x000C_0000 as *mut UWord
let MAGIC: UWord = 0xB55_0B55
let power: *volatile mut UWord = 0xFD00_4000 as *volatile mut UWord

let main(argc: UWord, argv: *UByte[]): Word {
    if *marker != MAGIC {
        *marker = MAGIC
        for i: UWord in 0..4 dirty[i] = 0xFFFF_FFFF
        puts("reset\n")
        power[1] = 1
    }
    *marker = 0
    puts("bss ")
    putu(dirty[0] | dirty[1] | dirty[2] | dirty[3])
    puts("\n")
    return 0
}
