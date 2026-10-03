// Local 'let' constants (3.2, 4.2): the compiler folds them into the code,
// so they can be an array length, a 'case' label or a step, and a constant
// whose address isn't taken gets no slot in the frame.
// @output "consts 32 7 64 1 2 0 4 2 42 43 2 1 44\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, sayu, nl } from "lib/print.m"

enum Direction: UByte {
    Up,
    Down,
    Left,
}

let classify(n: UWord): UWord {
    let small: UWord = 3
    let large: UWord = small * 10
    switch n {
        case small:
            return 1
        case large:
            return 2
    }
    return 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("consts")
    let n: UWord = 16
    let mut buf: UByte[n * 2]
    sayu(sizeof(UByte[n * 2]))
    buf[n * 2 - 1] = 7
    sayu(buf[31] as UWord)
    let total: UWord = n * 4
    sayu(total)
    sayu(classify(3))
    sayu(classify(30))
    sayu(classify(5))
    let step: UWord = 3
    let mut count: UWord = 0
    for i: UWord in 0..10 by step {
        count++
    }
    sayu(count)
    let d: Direction = Direction.Left
    sayu(d as UWord)
    // '&k': k gets a slot, but reading it by name is still the constant
    let k: Word = 42
    let p: *Word = &k
    say(*p)
    say(k + 1)
    let half: Float = 0.5
    say((half * 4.0) as Word)
    let on: Bool = true
    if on {
        sayu(1)
    }
    // typed: wraps like the machine (4.7), 200 + 100 = 44 in UByte
    let b: UByte = 200
    let c: UByte = b + 100
    sayu(c as UWord)
    nl()
    return 0
}
