// Warnings. This file compiles, but the compiler reports every line marked
// 'warning'. Unused parameters are not reported: callbacks and handlers
// have their signature given from outside.
//
// A lost function result is a warning too. There is no special syntax to
// drop a result: if a result is not needed, the function should not return it.

import { puts } from "externs.m"
import { Color } from "modules/color.m"     // warning: 'Color' is never used

let helper(): Void {}                        // warning: not exported and never called

let mut counter: UWord                       // warning: never used

let unusedVariable(): Void {
    let x: UWord = 1                         // warning: 'x' is never read
}

let neverChanged(): UWord {
    let mut y: UWord = 2                     // warning: 'y' is never changed,
    return y                                 // 'let' is enough
}

let unreachable(n: UWord): UWord {
    return n
    puts("never\n")                          // warning: unreachable code
}

let readBeforeWrite(): UWord {
    let mut z: UWord
    let w: UWord = z                         // warning: 'z' is read before it is written
    z = 1
    return w + z
}

let answer(): Word {
    return 42
}

let lostResult(): Void {
    answer()                                 // warning: the result of 'answer' is lost

    // Use it instead: there are no results that are not needed
    if answer() != 42 puts("wrong\n")
}

// No warning: 'frame' is unused, but the signature is fixed by the caller
let onTimer(code: UWord, frame: UWord): Void {
    puts("tick\n")
}

let main(argc: UWord, argv: *UByte[]): Word {
    unusedVariable()
    lostResult()
    let a: UWord = neverChanged()
    let b: UWord = unreachable(a)
    let c: UWord = readBeforeWrite()
    onTimer(b, c)
    return 0
}

// Test directives (m/tests/run.py): the warnings above, by line
// @warning 9: 'Color' is imported but never used
// @warning 11: 'helper' is not exported and never called
// @warning 13: 'counter' is never used
// @warning 16: 'x' is never read
// @warning 20: 'y' is never changed, so 'let' is enough
// @warning 26: unreachable code
// @warning 31: 'z' is read before it is written
// @warning 41: the result of 'answer' is lost
// @output "tick\n"
// @exit 0
