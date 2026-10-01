// Pointers:
//   *T      read-only: you can read through it, but not write
//   *mut T  writable
//   &x      gives *T
//   &mut x  gives *mut T, allowed only for 'let mut x'
//   *p      dereference, like in C; writing '*p = ...' needs 'p: *mut T'
//   p.f     field through a pointer: the same '.' as for a value, like in
//           Go and Zig. One level only: for 'pp: **T' write '(*pp).f'
//   p[i]    index a pointer, like in C; '&p[i]' is the address of an element
//   null    the null pointer, fits any *T and *mut T
//
// There is no pointer arithmetic ('p + i'): use '&p[i]'.
// '*mut T' converts to '*T' implicitly (it only drops the right to write).
// This is the only implicit conversion in the language.
// '*T' to '*mut T', integer to pointer and pointer to integer need 'as'.

import { puts } from "externs.m"

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

type UartRegs {
    data:    UWord,  // 0x00
    status:  UWord,  // 0x04
    control: UWord,  // 0x08
}

// The signature says what the function does with the memory:
// 'increment' writes into '*p', 'get' only reads it.
let increment(p: *mut UWord): Void {
    *p = *p + 1
}

let get(p: *UWord): UWord {
    return *p
    // Compile error: 'p' is *UWord, writing needs *mut UWord
    //     *p = 0
}

// '*dst = *src' copies the whole struct
let colorCopy(dst: *mut Color, src: *Color): Void {
    *dst = *src
}

let colorClear(c: *mut Color): Void {
    *c = {}  // all fields are zero
}

// '.' works the same for a value and for a pointer
let colorBrighten(c: *mut Color): Void {
    c.r = c.r +| 0x10
    c.g = c.g +| 0x10
    c.b = c.b +| 0x10
}

let colorRedOf(c: *Color): UByte {
    return c.r
    // Compile error: 'c' is *Color, writing needs *mut Color
    //     c.r = 0
}

let colorRedOfRef(pp: **Color): UByte {
    // '.' dereferences one level only
    return (*pp).r
    // Compile error: 'pp.r' would need two levels
    //     return pp.r
}

let resetIfSet(p: *mut UWord): Void {
    // The body starts with '*', so the condition goes in parentheses.
    // Without them it reads as 'p != (null * p) = 0', which is an error.
    if (p != null) *p = 0

    // Or a block
    if p != null { *p = 0 }
}

let strlen(s: *UByte): UWord {
    // Index a pointer like an array
    let mut n: UWord = 0
    while s[n] != 0 n++
    return n
}

let printName(name: *UByte): Void {
    if name == null puts("(no name)") else puts(name)
    puts("\n")
}

let pointers(): Void {
    let mut counter: UWord = 0
    increment(&mut counter)          // counter = 1
    let value: UWord = get(&counter) // 1

    let red: Color = { .r = 0xFF }
    let mut c: Color = {}

    colorCopy(&mut c, &red)          // &mut c: *mut Color, &red: *Color
    colorBrighten(&mut c)
    let r1: UByte = colorRedOf(&c)   // 0xFF
    colorClear(&mut c)

    // The same '.' on a value and on a pointer
    let pc: *Color = &red
    let r2: UByte = red.r
    let r3: UByte = pc.r
    let r4: UByte = colorRedOfRef(&pc)

    // Compile errors:
    //     colorClear(&red)          // &red is *Color, but *mut Color is needed
    //     colorClear(&mut red)      // 'red' is not 'let mut'

    // '*mut T' goes where '*T' is expected without 'as'
    let w: *mut Color = &mut c
    let r: *Color = w
    let mut copy: Color = {}
    colorCopy(&mut copy, r)
    colorCopy(&mut copy, w)          // also in an argument

    // Back to '*mut T' only with 'as'
    //     let w2: *mut Color = r    // compile error
    let w2: *mut Color = r as *mut Color

    // Address of an element: '&p[i]', not 'p + i'
    let hello: *UByte = "Hello"
    let ello: *UByte = &hello[1]
    puts(ello)
    let len: UWord = strlen(ello)    // 4

    // String literals live in .rodata and have type *UByte, so writing into
    // them is a compile error, not a page fault at run time.
    //     hello[0] = 'J'            // compile error
    printName(hello)
    printName(null)

    // 'let mut p: *T': the pointer can be moved, the memory is read-only
    let mut name: *UByte = "first"
    printName(name)
    name = "second"
    printName(name)
}

// 'let p: *mut T': the pointer is fixed, the memory is writable.
// An integer address becomes a pointer only with 'as'.
// Device registers also need 'volatile', see mmio.m.
let uart: *volatile mut UartRegs = 0xFD002000 as *volatile mut UartRegs

let main(argc: UWord, argv: *UByte[]): Word {
    pointers()

    let address: UWord = uart as UWord  // 0xFD002000
    if argv[0] != null printName(argv[0])
    return 0
}

// Test directives (m/tests/run.py)
// @output "elloHello\n(no name)\nfirst\nsecond\n"
// @exit 0
