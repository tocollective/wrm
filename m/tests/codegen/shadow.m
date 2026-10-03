// Shadowing (3.7): a name of an inner block hides the outer one up to the
// end of the block, and its initializer still sees the outer one. A nested
// function doesn't see the locals around it (3.8), so it sees the global.
// @output "shadow 1 2 12 1 7 5 7 7 9 1 12 -1 21\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, nl } from "lib/print.m"

let x: Word = 7

let f(n: Word): Word {
    if n > 0 {
        let n: Word = n * 4             // the parameter on the right
        return n
    }
    return n
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("shadow")
    let a: Word = 1
    say(a)                              // 1
    {
        let a: Word = a + 1             // 'a' on the right is the outer one
        say(a)                          // 2
        {
            let a: Word = a * 6
            say(a)                      // 12
        }
    }
    say(a)                              // 1: the outer one again
    say(x)                              // 7: the global
    {
        let x: Word = 5                 // hides the global
        say(x)                          // 5
        // main's locals aren't visible in a nested function: 'x' is the global
        let g(): Word { return x }
        say(g())                        // 7
    }
    say(x)                              // 7
    {
        let mut a: Word = 0             // a variable of its own
        a = 9
        say(a)                          // 9
    }
    say(a)                              // 1
    say(f(3))                           // 12
    say(f(-1))                          // -1
    let mut total: UWord = 0
    for i: UWord in 0..2 {
        let i: UWord = i + 10
        total += i
    }
    say(total as Word)                  // 21
    nl()
    return 0
}
