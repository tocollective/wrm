// Frames over 8KB: offsets past imm14 go through r9 (7.8).
// @output "frame 1 5000 3 9000\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { sayu, nl } from "lib/print.m"

type Big {
    data: UByte[5000],
    tail: UWord,
}

let deep(n: UWord): UWord {
    let mut big: UWord[3000]
    big[2999] = n
    let mut b: Big = {}
    b.tail = 3
    b.data[4999] = 9
    return big[2999] + b.tail * 1000 + (b.data[4999] as UWord) * 1000 - 3000
}

let main(argc: UWord, argv: *UByte[]): Word {
    let mut far: UByte[10000]
    far[9999] = 1
    puts("frame")
    sayu(far[9999] as UWord)
    sayu(deep(5000) - 9000)
    sayu(sizeof(Big) / 1668)
    sayu(deep(0))
    nl()
    return 0
}
