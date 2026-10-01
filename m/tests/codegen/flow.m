// Control flow: the 'for' table of 5.7, 'for mut', 'break' and
// 'continue', 'while', short-circuit '&&' and '||', 'switch' with
// fall-through, the dangling 'else'.
// @output "for 0 256 5:20 11:55 86:0 0 0 256 3:-1 5 1 5 3\n"
// @output "while 10 4 6\n"
// @output "logic 1 0 2 1\n"
// @output "switch 3 2 1 go | 2 1 go | go | 30 31 28 | 4\n"
// @output "else b !b a\n"
// @exit 3

import { puts } from "../../examples/externs.m"
import { putd, say, nl } from "lib/print.m"

/// Writes " n:m".
let pair(n: Word, m: Word): Void {
    say(n)
    puts(":")
    putd(m)
}

let forLoops(argc: UWord): Void {
    puts("for")
    let mut n: UWord = 0
    for i: UWord in 0..argc n++
    say(n as Word)

    n = 0
    for i: UByte in 0...0xFF n++
    say(n as Word)

    n = 0
    let mut sum: UWord = 0
    for i: UWord in 0...9 by 2 {
        n++
        sum += i
    }
    pair(n as Word, sum as Word)

    n = 0
    sum = 0
    for i: UWord in 10...0 by -1 {
        n++
        sum += i
    }
    pair(n as Word, sum as Word)

    n = 0
    let mut last: UByte = 1
    for i: UByte in 0xFF...0 by -3 {
        n++
        last = i
    }
    pair(n as Word, last as Word)

    n = 0
    for i: UWord in argc..0 by -1 n++
    say(n as Word)

    n = 0
    for i: UWord in 5..5 n++
    say(n as Word)

    n = 0
    for i: Byte in -128...127 n++
    say(n as Word)

    n = 0
    let mut lastw: Word = 0
    for i: Word in 3..-3 by -2 {
        n++
        lastw = i
    }
    pair(n as Word, lastw)

    // 'for mut': the body moves the variable
    n = 0
    for mut i: UWord in 0..10 {
        n++
        i++
    }
    say(n as Word)
    n = 0
    for mut i: UWord in 0..10 {
        n++
        i = i + 20
    }
    say(n as Word)

    // 'continue' goes to the checks, 'break' leaves
    n = 0
    for i: UWord in 0..10 {
        if i % 2 == 0 continue
        n++
    }
    say(n as Word)
    n = 0
    for i: UWord in 0..100 {
        if i == 3 break
        n++
    }
    say(n as Word)
    nl()
}

let whileLoops(): Void {
    puts("while")
    let mut i: UWord = 0
    while i < 10 i++
    say(i as Word)

    let mut found: UWord = 0
    i = 0
    while true {
        i++
        if i == 4 {
            found = i
            break
        }
    }
    say(found as Word)

    // nested: count pairs (a, b) with a < b < 4; continue skips
    let mut pairs: UWord = 0
    let mut a: UWord = 0
    while a < 4 {
        let mut b: UWord = 0
        while b < 4 {
            b++
            if b - 1 <= a continue
            pairs++
        }
        a++
    }
    say(pairs as Word)
    nl()
}

let mut calls: UWord

let touch(result: Bool): Bool {
    calls++
    return result
}

let logic(): Void {
    puts("logic")
    calls = 0
    if touch(false) && touch(true) puts("?")
    say(calls as Word)
    calls = 0
    if touch(true) || touch(true) {} else puts("?")
    say((calls - 1) as Word)
    calls = 0
    let both: Bool = touch(true) && touch(false)
    say(calls as Word)
    say((!both) as Word)
    nl()
}

let countdown(n: UWord): Void {
    switch n {
        case 3:
            puts(" 3")
        case 2:
            puts(" 2")
        case 1:
            puts(" 1")
        default:
            puts(" go")
    }
}

let days(month: UWord): UWord {
    switch month {
        case 2:
            return 28
        case 4:
        case 6:
        case 9:
        case 11:
            return 30
    }
    return 31
}

let switches(): Void {
    puts("switch")
    countdown(3)
    puts(" |")
    countdown(2)
    puts(" |")
    countdown(7)
    puts(" |")
    say(days(4) as Word)
    say(days(1) as Word)
    say(days(2) as Word)
    puts(" |")
    // 'break' leaves the switch, 'continue' the loop iteration
    let mut n: UWord = 0
    for i: UWord in 0..10 {
        switch i {
            case 0:
                continue
            case 5:
                break
            default:
                n++
                continue
        }
        n = n + 100
        break
    }
    say((n - 100) as Word)
    nl()
}

let elses(a: Bool, b: Bool): Void {
    if a
        if b puts(" b")
        else puts(" !b")
}

let main(argc: UWord, argv: *UByte[]): Word {
    forLoops(argc)
    whileLoops()
    logic()
    switches()
    puts("else")
    elses(true, true)
    elses(true, false)
    elses(false, true)
    if argc == 0 puts(" a") else puts(" z")
    nl()
    return 3
}
