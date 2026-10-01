// Expressions and statements:
//   - '=', '+=', '-=' and the others, '++', '--' are statements, not
//     expressions: they have no value
//   - '&', '|', '^' bind tighter than comparisons
//   - 'as' binds tighter than arithmetic
//   - comparisons do not chain: 'a < b < c' is an error
//   - '!' is logical not for Bool, '~' is bitwise not for integers
//   - conditions of 'if' and 'while' and operands of '&&', '||', '!' must be
//     Bool: no 'if n' or 'if p', compare with 0 or null instead
//   - '&&' and '||' short-circuit
//   - function arguments are evaluated left to right
//   - the type of every variable is written explicitly
//
// Precedence, from tightest:
//   f()  a[i]  a.b
//   unary  -  !  ~  *  &  &mut
//   as
//   *  /  %  *|
//   +  -  +|  -|
//   <<  >>
//   &
//   ^
//   |
//   ==  !=  <  <=  >  >=
//   &&
//   ||

import { puts } from "externs.m"

let UART_TX_READY: UWord = 0b10

let statements(): Void {
    let mut i: UWord = 0
    i++
    i += 2
    i <<= 1
    i |= 0x100

    // Compile errors: assignment and '++' have no value
    //     let j: UWord = i++
    //     if i = 0 puts("zero")
    //     a = b = 0
    //     buf[i++] = 0
}

let precedence(status: UWord, a: UByte, b: UWord): Void {
    // (status & UART_TX_READY) == 0, not status & (UART_TX_READY == 0) as in C
    if status & UART_TX_READY == 0 puts("busy\n")

    // (a as UWord) + b: 'as' first, then '+'
    let sum: UWord = a as UWord + b

    // (status >> 4) & 0xF
    let nibble: UWord = status >> 4 & 0xF

    // 1 + (2 * 3) = 7, as usual
    let seven: UWord = 1 + 2 * 3

    // Compile error: comparisons do not chain
    //     if 0 < b < 10 puts("small")
    if 0 < b && b < 10 puts("small\n")
}

let check(name: *UByte): Bool {
    puts(name)
    return true
}

let logic(p: *UByte, flags: UWord): Void {
    // '&&' stops at the first false: p[0] is not read when p is null
    if p != null && p[0] != 0 puts(p)

    // Compile errors: the condition is not Bool
    //     if flags puts("set")
    //     if p puts(p)
    if flags != 0 puts("set\n")

    let off: Bool = !check("a")
    let asNumber: UByte = off as UByte  // false = 0, true = 1
    let inverted: UWord = ~flags

    // Arguments are evaluated left to right: prints "a", then "b"
    let both: Bool = check("a") && check("b")
}

let main(argc: UWord, argv: *UByte[]): Word {
    statements()
    precedence(0xF0, 1, 2)
    logic(argv[0], 0)
    return 0
}

// Test directives (m/tests/run.py)
// @output "busy\nsmall\na" "a" "b"
// @exit 0
