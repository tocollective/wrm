// 'while' and 'for' follow the same rule as 'if': the body is either a block
// in '{}' or exactly one statement. The condition (or the range) is the
// longest expression, and the statement starts at the first token that
// cannot continue it.

import { puts } from "externs.m"

let printArgs(argc: UWord, argv: *UByte[]): Void {
    // One statement without braces
    for i: UWord in 0..argc puts(argv[i])

    // Or on the next line
    for i: UWord in 0..argc
        puts(argv[i])

    // The body can be another loop or 'if': skip the program name
    for i: UWord in 0..argc
        if i > 0 puts(argv[i])

    // Blocks for more than one statement
    let mut i: UWord = 0
    while i < argc {
        puts(argv[i])
        puts("\n")
        i++
    }
}

let countArgs(argc: UWord, argv: *UByte[]): UWord {
    // 'while' with one statement
    let mut n: UWord = 0
    while n < argc n++
    return n
}

// 'break' leaves the loop, 'continue' goes to the next iteration.
// There are no labels: to leave two loops at once, use a flag or 'return'.
let findArg(argc: UWord, argv: *UByte[], first: UByte): UWord {
    let mut found: UWord = argc
    for i: UWord in 0..argc {
        if argv[i][0] == 0 continue  // skip empty arguments
        if argv[i][0] == first {
            found = i
            break
        }
    }
    return found
}

let hasEmptyArg(argc: UWord, argv: *UByte[]): Bool {
    // Leaving two loops: a flag
    let mut empty: Bool = false
    for i: UWord in 0..argc {
        let mut j: UWord = 0
        while argv[i][j] != 0 j++
        if j == 0 {
            empty = true
            break
        }
    }
    return empty
}

// 'while true' is the infinite loop. Without 'break' in it, the compiler
// knows it never ends, so no 'return' is needed after it.
let waitForever(): UWord {
    let mut ticks: UWord = 0
    while true {
        ticks++
    }
}

let main(argc: UWord, argv: *UByte[]): Word {
    let dash: UWord = findArg(argc, argv, '-')
    let empty: Bool = hasEmptyArg(argc, argv)
    printArgs(argc, argv)
    let n: UWord = countArgs(argc, argv)
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
