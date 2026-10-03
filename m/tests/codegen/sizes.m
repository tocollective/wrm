// 'T[]' with an array literal (3.2) and 'sizeof'/'alignof' of a value
// (7.2): names of variables are values, '*p[0]' is '*(p[0])', and the value
// isn't computed.
// @output "sizes 3 12 5 2 8 2 4 2 3 6 2 4 4 0 one two\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, sayu, nl } from "lib/print.m"

type StringPtr = *UByte

type Pair {
    a: UHalf,
    b: UWord,
}

let GLOBAL: UHalf[] = [1, 2, 3]
let mut calls: UWord = 0

let bump(): UWord {
    calls++
    return 7
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("sizes")
    sayu(sizeof(GLOBAL) / sizeof(GLOBAL[0]))
    let mut words: Word[] = [10, 20, 30]
    words[2] = 5
    sayu(sizeof(words))
    say(words[2])
    let bar: StringPtr[] = ["one", "two"]
    sayu(sizeof(bar) / sizeof(StringPtr))
    let pair: Pair = { .a = 1, .b = 2 }
    let p: *Pair = &pair
    sayu(sizeof(*p))
    sayu(sizeof(p.a))
    sayu(alignof(pair))
    let grid: UByte[3][] = [[1, 2, 3], [4, 5, 6]]
    sayu(sizeof(grid) / sizeof(grid[0]))
    sayu(sizeof(grid[0]))
    let pa: *(UHalf[3]) = &GLOBAL
    sayu(sizeof(*pa))
    sayu(sizeof((*pa)[0]))
    let x: Word = 1
    let y: Word = 2
    let ptrs: *Word[] = [&x, &y]
    sayu(sizeof(*ptrs[0]))
    sayu(sizeof(bump()))
    sayu(calls)
    for i: UWord in 0..sizeof(bar) / sizeof(bar[0]) {
        puts(" ")
        puts(bar[i])
    }
    nl()
    return 0
}
