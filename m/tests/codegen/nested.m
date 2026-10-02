// Functions in functions and function literals (3.8): every one is a
// function of its own with a local symbol. The same name in two blocks,
// nesting several levels deep, results and arguments of every kind, and
// literals in global initializers.
// @output "same 1 2\n"
// @output "deep 6 10\n"
// @output "big 1 2 3 4 | 55\n"
// @output "table 7 12 3\n"
// @output "mut 0 1 4 9\n"
// @output "void 42\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, nl } from "lib/print.m"

type Big {
    a: Word,
    b: Word,
    c: Word,
    d: Word,
}

type Entry {
    name: *UByte,
    op: (a: Word, b: Word): Word,
}

let table: Entry[2] = [
    { .name = "add", .op = (a: Word, b: Word): Word { return a + b } },
    { .name = "mul", .op = (a: Word, b: Word): Word { return a * b } },
]

// A top-level literal sees the top-level names
let mut pick(i: UWord): Word {
    return table[i].op(1, 2)
}

let sameName(): Void {
    puts("same")
    {
        let one(): Word { return 1 }
        say(one())
    }
    {
        let one(): Word { return 2 }       // another function: nested__sameName__one_2
        say(one())
    }
    nl()
}

let deep(): Void {
    puts("deep")
    let level1(x: Word): Word {
        let level2(x: Word): Word {
            let level3(x: Word): Word {
                return x + 1
            }
            return level3(x) * 2
        }
        return level2(x)
    }
    say(level1(2))
    // a literal in a nested function calls a nested function declared above
    let base(): Word { return 4 }
    let plusBase: (x: Word): Word = (x: Word): Word { return x + base() + 2 }
    say(plusBase(4))
    nl()
}

let big(): Void {
    puts("big")
    let make: (a: Word): Big = (a: Word): Big {
        let r: Big = { .a = a, .b = a + 1, .c = a + 2, .d = a + 3 }
        return r
    }
    let r: Big = make(1)
    say(r.a)
    say(r.b)
    say(r.c)
    say(r.d)
    puts(" |")
    // ten arguments: the last two on the stack
    let sum10(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, g: Word, h: Word,
              i: Word, j: Word): Word {
        return a + b + c + d + e + f + g + h + i + j
    }
    say(sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
    nl()
}

let main(argc: UWord, argv: *UByte[]): Word {
    sameName()
    deep()
    big()

    puts("table")
    say(table[0].op(3, 4))
    say(table[1].op(3, 4))
    say(pick(0))
    nl()

    puts("mut")
    let mut f(x: Word): Word { return 0 }
    for i: Word in 0..4 {
        say(f(i))
        f = (x: Word): Word { return x * x }
    }
    nl()

    puts("void")
    let answer(): Word { return 42 }
    let raw: *Void = answer as *Void
    let back: (): Word = raw as (): Word
    say(back())
    nl()
    return 0
}
