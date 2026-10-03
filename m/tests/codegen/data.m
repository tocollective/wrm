// Data: globals in .rodata, .data and .bss, constant initializers with
// addresses, pointers, struct and array values, array parameters.
// @output "globals 4095 255,0,0 hello hi hey 0 0,255,0 128 1 tick tick 2\n"
// @output "pointers 1 2 5 ello 4 1 1 7\n"
// @output "values 1 9 | 5 6 7 | 3 0 | 100 4\n"
// @output "arrays 672 672 8 3 11\n"
// @output "bss 4008\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { putd, say, sayu, nl } from "lib/print.m"

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

let PAGE_SIZE: UWord = 4096
let PAGE_MASK: UWord = PAGE_SIZE - 1
let RED: Color = { .r = 0xFF }
let GREETINGS: *UByte[3] = ["hello", "hi", "hey"]

let mut ticks: UWord
let mut current: Color = { .g = 0xFF }
let mut screen: UByte[4000]
let currentPtr: *mut Color = &mut current

let tick(): Void {
    ticks++
    puts(" tick")
}

let onTick: (): Void = tick

let showColor(c: Color): Void {
    puts(" ")
    putd(c.r as Word)
    puts(",")
    putd(c.g as Word)
    puts(",")
    putd(c.b as Word)
}

let globals(): Void {
    puts("globals")
    sayu(PAGE_MASK)
    showColor(RED)
    for i: UWord in 0..3 {
        puts(" ")
        puts(GREETINGS[i])
    }
    sayu(ticks)
    showColor(current)
    currentPtr.r = 0x80
    sayu(current.r as UWord)
    sayu(screen[3999] as UWord + 1)
    onTick()
    onTick()
    sayu(ticks)
    nl()
}

let increment(p: *mut UWord): Void {
    *p = *p + 1
}

let strlen(s: *UByte): UWord {
    let mut n: UWord = 0
    while s[n] != 0 n++
    return n
}

let redOfRef(pp: **Color): UByte {
    return (*pp).r
}

let pointers(): Void {
    puts("pointers")
    let mut counter: UWord = 0
    increment(&mut counter)
    sayu(counter)
    increment(&mut counter)
    let pc: *UWord = &counter
    sayu(*pc)
    let mut c: Color = {}
    let w: *mut Color = &mut c
    w.b = 5
    sayu(c.b as UWord)
    let hello: *UByte = "Hello"
    puts(" ")
    puts(&hello[1])
    sayu(strlen(&hello[1]))
    let mut name: *UByte = null
    sayu((name == null) as UWord)
    name = "x"
    sayu((name != null) as UWord)
    let r: *Color = w
    c.r = 7
    sayu(redOfRef(&r) as UWord)
    nl()
}

type Point {
    x: Word,
    y: Word,
}

type Shape {
    origin: Point,
    corners: Point[3],
    color: Color,
}

let values(): Void {
    puts("values")
    // arrays and structs are values: a copy is separate
    let mut a: Word[2] = [1, 2]
    let b: Word[2] = a
    a[1] = 9
    say(b[0])
    say(a[1])
    puts(" |")
    let mut s: Shape = { .origin = { .x = 5 }, .corners = [{}, { .y = 6 }], .color = { .b = 7 } }
    say(s.origin.x)
    say(s.corners[1].y)
    say(s.color.b as Word)
    puts(" |")
    let mut t: Shape = s
    t.corners[2] = { .x = 3 }
    s = {}
    say(t.corners[2].x)
    say(s.origin.x)
    puts(" |")
    let mut shapes: Shape[2]
    shapes[1] = t
    shapes[1].origin.y = 100
    let sp: *mut Shape = &mut shapes[1]
    say(sp.origin.y)
    let mut i: UWord = 1     // not a constant: the index is computed
    say(shapes[i].color.b as Word - 3)
    nl()
}

let fill(buf: mut UByte[], n: UWord, value: UByte): Void {
    for i: UWord in 0..n buf[i] = value
}

let sum(buf: UByte[], n: UWord): UWord {
    let mut total: UWord = 0
    for i: UWord in 0..n total = total + (buf[i] as UWord)
    return total
}

let mut table: UByte[4]

let arrays(): Void {
    puts("arrays")
    let mut buf: UByte[16]
    fill(buf, 16, 0x2A)
    sayu(sum(buf, 16))
    let p: *UByte = &buf[0]
    sayu(sum(p, 16))
    fill(table, 4, 1)
    table[2] = 5
    sayu(sum(table, 4))
    let digits: UByte[3] = [1, 2]
    sayu(sum(digits, 3))
    let more: UByte[4] = [1, 2, 3, 5]
    sayu(sum(more, 4))
    nl()
}

extern let __bss_start: UByte
extern let __bss_end: UByte

let main(argc: UWord, argv: *UByte[]): Word {
    globals()
    pointers()
    values()
    arrays()
    puts("bss")
    // ticks (4), screen (4000), table (4)
    sayu((&__bss_end as UWord) - (&__bss_start as UWord))
    nl()
    return 0
}
