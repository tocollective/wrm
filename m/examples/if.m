// 'if' / 'else' body is either a block in '{}' or exactly one statement.
//
// The condition is the longest expression after 'if'. It ends at the first
// token that cannot continue the expression, and the statement starts there.
//     if x -y       is   if (x - y) ...   not   if x { -y }
//
// If '(' comes right after 'if' or 'while', the condition is exactly what is
// inside these parentheses, like in C. This is how to write a body that
// starts with '-', '*', '&', '(' or '[':
//     if (p != null) *p = 0
//
// 'else' belongs to the nearest 'if' without an 'else'.

import { puts } from "externs.m"

let describe(n: Word): Void {
    // Blocks
    if n == 0 {
        puts("zero")
    } else if n > 0 {
        puts("positive")
    } else {
        puts("negative")
    }
    puts("\n")
}

let clampToByte(n: Word): Word {
    // One statement without braces
    if n < 0 return 0
    if n > 255 return 255
    return n
}

let sign(n: Word): Void {
    // 'else' with one statement too, also on one line
    if n < 0 puts("-") else puts("+")

    // or split over lines: newlines do not matter
    if n == 0
        puts("zero")
    else
        puts("non-zero")
}

let nested(a: Bool, b: Bool): Void {
    // The body can be another 'if'. This 'else' belongs to 'if b':
    if a
        if b puts("a and b\n")
        else puts("a and not b\n")

    // To attach 'else' to 'if a', use braces:
    if a {
        if b puts("a and b\n")
    } else {
        puts("not a\n")
    }
}

let parens(p: *mut Word, n: Word): Void {
    // Without parentheses this is 'p != (null * p) = 0': an error
    if (p != null) *p = 0
    if (n < 0) *p = -n

    // The parentheses end the condition, so a condition that only starts
    // with '(' must be wrapped whole:
    //     if (n + 1) * 2 > 10 puts("big")     // compile error:
    //                                         // condition '(n + 1)', body '* 2 > 10 ...'
    if ((n + 1) * 2 > 10) puts("big")
    if 2 * (n + 1) > 10 puts("big")
}

let main(argc: UWord, argv: *UByte[]): Word {
    describe(-5)
    sign(clampToByte(300))
    nested(true, false)

    let mut v: Word = 0
    parens(&mut v, -3)

    let mut flag: Bool = false
    if flag == false flag = true

    return 0
}

// Test directives (m/tests/run.py)
// @output "negative\n+non-zero" "a and not b\n"
// @exit 0
