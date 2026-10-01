// Arrays:
//   T[N]       a value of N elements: copied on assignment and when passed
//   T[]        in a parameter: a pointer to the first element, read-only.
//              The same type as '*T'
//   mut T[]    in a parameter: a pointer to the first element, writable.
//              The same type as '*mut T'
//   *UByte[4]  '[]' applies to the whole type on the left:
//              an array of 4 pointers to UByte
//   *(UByte[4]) a pointer to an array of 4 UByte
//
// An array passed to a 'T[]' or 'mut T[]' parameter becomes a pointer to its
// first element, like in C. Only a 'let mut' array goes to 'mut T[]'.
// Everywhere else 'T[N]' stays a value.
//
// Array literal: '[1, 2, 3]'. Elements that are not given are zero,
// like struct fields: '[1, 2]' for UByte[4] is 1, 2, 0, 0, and '[]' is all
// zeros. More elements than N is an error.
//
// The length is passed separately: there are no slices and no '.len'.
// There are no bounds checks.

import { puts } from "externs.m"

let fill(buf: mut UByte[], n: UWord, value: UByte): Void {
    for i: UWord in 0..n buf[i] = value
}

let sum(buf: UByte[], n: UWord): UWord {
    let mut total: UWord = 0
    for i: UWord in 0..n total = total + (buf[i] as UWord)
    return total

    // Compile error: 'buf' is read-only
    //     buf[0] = 0
}

let printAll(lines: *UByte[], n: UWord): Void {
    for i: UWord in 0..n {
        puts(lines[i])
        puts("\n")
    }
}

// Literals work for globals too: they are constants
let SQUARES: UWord[8] = [0, 1, 4, 9, 16, 25, 36, 49]
let GREETINGS: *UByte[3] = ["hello", "hi", "hey"]

type Point {
    x: Word,
    y: Word,
}

let literals(): Void {
    let digits: UByte[4] = [1, 2, 3, 4]
    let padded: UByte[8] = [1, 2]             // 1, 2, 0, 0, 0, 0, 0, 0
    let zeros: UByte[64] = []                 // all zeros

    // One element per line, trailing comma allowed
    let corners: Point[4] = [
        { .x = 0,  .y = 0 },
        { .x = 10, .y = 0 },
        { .x = 10, .y = 10 },
        { .x = 0,  .y = 10 },
    ]

    let total: UWord = sum(digits, 4)        // 10

    // Compile error: 5 elements do not fit in UByte[4]
    //     let tooMany: UByte[4] = [1, 2, 3, 4, 5]
}

let main(argc: UWord, argv: *UByte[]): Word {
    literals()
    printAll(GREETINGS, 3)
    // No '=': no initial value, 'fill' writes every element
    let mut buf: UByte[16]
    fill(buf, 16, 0x2A)
    let total: UWord = sum(buf, 16)      // 16 * 0x2A = 672

    // 'T[]' and '*T' are the same type, so a pointer goes where an
    // array parameter is expected and back
    let p: *UByte = &buf[0]          // here 'buf' is not an argument, so '&buf[0]'
    let again: UWord = sum(p, 16)

    // T[N] is a value: 'copy' is a separate array
    let copy: UByte[16] = buf

    // Compile error: 'copy' is not 'let mut', so it cannot go to 'mut UByte[]'
    //     fill(copy, 16, 0)

    printAll(argv, argc)
    return 0
}

// Test directives (m/tests/run.py)
// @output "hello\nhi\nhey\n"
// @exit 0
