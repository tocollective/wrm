// *Void: a pointer to data of an unknown type, like 'void *' in C (2.4).
//
//   *Void, *mut Void, *volatile Void, *volatile mut Void
//
// Any pointer becomes *Void of the same kind by itself: the type of the
// data is lost, and no right is added ('mut' may be dropped, 'volatile'
// added). Back to a typed pointer only with 'as'. Nothing can be read or
// written through *Void: '*p', 'p[i]' and 'p.f' need 'as' first.
//
// A function converts to *Void and back with 'as'.
//
// The usual use: a context for a callback. A nested function or a function
// literal can't capture the locals around it (3.8), so they come through
// a *Void parameter.

import { puts } from "externs.m"

type Item {
    size: UWord,
    next: *Item,
}

type Visit = (item: *Item, ctx: *mut Void): Void

/// Calls visit for every item of the list, passing ctx along.
let forEach(first: *Item, visit: Visit, ctx: *mut Void): Void {
    let mut p: *Item = first
    while p != null {
        visit(p, ctx)
        p = p.next
    }
}

/// Fills n bytes at dst with b, whatever dst points to.
let fill(dst: *mut Void, b: UByte, n: UWord): Void {
    let bytes: *mut UByte = dst as *mut UByte
    for i: UWord in 0..n bytes[i] = b
}

let hello(): Void {
    puts("hello\n")
}

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Item = { .size = 3 }
    let b: Item = { .size = 20, .next = &c }
    let a: Item = { .size = 100, .next = &b }

    let mut total: UWord = 0
    forEach(&a, (item: *Item, ctx: *mut Void): Void {
        let sum: *mut UWord = ctx as *mut UWord
        sum[0] += item.size             // not "*sum": it would continue the line above (5.1)
    }, &mut total)                          // *mut UWord becomes *mut Void
    if total == 123 puts("total ok\n")

    let mut words: UWord[2]
    fill(&mut words, 0xAB, 8)               // *mut (UWord[2]) becomes *mut Void
    if words[0] == 0xABABABAB && words[1] == 0xABABABAB puts("fill ok\n")

    // Any pointer becomes *Void; mut can be dropped
    let any: *Void = &mut total
    if any == &total puts("same address\n")

    // A function and *Void, both ways with 'as'
    let raw: *Void = hello as *Void
    let back: (): Void = raw as (): Void
    back()                                  // "hello"

    // Compile errors:
    //     let n: UWord = *any              // nothing can be read through *Void
    //     let p: *UWord = any              // *Void becomes *UWord only with 'as'
    //     let w: *mut Void = &total        // *UWord can't become *mut Void
    //     let v: Void                      // Void only as a result and after '*'
    return 0
}

// Test directives (m/tests/run.py)
// @output "total ok\nfill ok\nsame address\nhello\n"
// @exit 0
