// Dynamic arrays and their sizes.
//
// M has no heap, no slices and no '.len' (2.5). An array whose length is
// known only at run time is a struct: a pointer to the elements, their
// number and the capacity. The memory comes from an allocator written in M;
// without an OS it is a bump allocator over a global arena.
//
// Sizes:
//   sizeof(a)                 bytes of a fixed array 'a': a constant (7.2)
//   sizeof(a) / sizeof(a[0])  its number of elements, also a constant
//   v.len                     elements of a dynamic array, known at run time
//   v.len * sizeof(T)         the bytes they take
//   v.cap * sizeof(T)         the bytes the array holds
//
// 'sizeof' takes a type or a value, like in C; the value isn't computed.
// A 'T[]' parameter is only a pointer, so its length is passed separately,
// and 'sizeof' of it is an error.
// There are no generic types: the dynamic array below holds 'Word'.

import { puts } from "externs.m"

// -- the allocator

let ARENA_SIZE: UWord = 1024
align(4) let mut arena: UByte[ARENA_SIZE]
let mut arenaUsed: UWord = 0

/// n bytes from the arena, aligned to 4; null when it is full. Nothing is
/// ever freed: a real allocator would keep a list of free blocks.
let alloc(n: UWord): *mut Void {
    let size: UWord = (n + 3) / 4 * 4
    if size > ARENA_SIZE - arenaUsed return null
    let p: *mut Void = &mut arena[arenaUsed]
    arenaUsed += size
    return p
}

// -- the dynamic array

type WordVec {
    data: *mut Word,   // null while empty
    len:  UWord,       // elements in use
    cap:  UWord,       // elements that fit in 'data'
}

/// Appends x; when the array is full, moves it into a block twice as
/// large. False when the arena is full.
let vecPush(v: *mut WordVec, x: Word): Bool {
    if v.len == v.cap {
        let mut newCap: UWord = v.cap * 2
        if newCap == 0 newCap = 4
        let p: *mut Word = alloc(newCap * sizeof(Word)) as *mut Word
        if p == null return false
        for i: UWord in 0..v.len p[i] = v.data[i]
        v.data = p
        v.cap = newCap
    }
    v.data[v.len] = x
    v.len++
    return true
}

/// Bytes the elements take.
let vecBytes(v: *WordVec): UWord {
    return v.len * sizeof(Word)
}

// 'Word[]' is a pointer: the length comes as a separate argument, so the
// same function sums a fixed array and a dynamic one
let sum(xs: Word[], n: UWord): Word {
    // Compile error: 'xs' is a pointer, the length isn't known
    //     let count: UWord = sizeof(xs) / sizeof(xs[0])
    let mut total: Word = 0
    for i: UWord in 0..n total += xs[i]
    return total
}

// -- fixed arrays

// 'T[]' with a literal: the length is the number of elements (3.2), here
// Word[6]. 'sizeof' gives it back
let PRIMES: Word[] = [2, 3, 5, 7, 11, 13]
let PRIMES_BYTES: UWord = sizeof(PRIMES)                        // 24
let PRIMES_COUNT: UWord = sizeof(PRIMES) / sizeof(PRIMES[0])    // 6

let fixed(): Word {
    // A local 'let' is a constant too (3.2), so it can be a length
    let n: UWord = 5
    let mut squares: Word[n]
    for i: UWord in 0..n squares[i] = (i * i) as Word
    if sizeof(squares) != 20 return 1
    if sum(squares, n) != 30 return 2       // 0 + 1 + 4 + 9 + 16
    if PRIMES_BYTES != 24 || PRIMES_COUNT != 6 return 3
    let names: *UByte[] = ["one", "two", "three"]
    if sizeof(names) / sizeof(names[0]) != 3 return 4
    return 0

    // Compile error: the length of an array is a constant
    //     let mut buf: Word[argc]
    // Compile error: the length of 'T[]' comes from an array literal
    //     let mut buf: Word[]
}

// -- a dynamic array

let dynamic(): Word {
    let mut v: WordVec = {}            // empty: data = null, len = cap = 0
    for i: UWord in 0..PRIMES_COUNT {
        if !vecPush(&mut v, PRIMES[i]) return 10
    }
    // the fifth push outgrows 4 elements: the array moves into 8
    if v.len != 6 return 11
    if v.cap != 8 return 12
    if vecBytes(&v) != 24 return 13               // 6 * 4
    if v.cap * sizeof(Word) != 32 return 14       // 8 * 4
    if arenaUsed != 48 return 15                  // 16 for 4 elements, then 32 for 8
    if sum(v.data, v.len) != 41 return 16         // 2 + 3 + 5 + 7 + 11 + 13

    // A length from run time: as many elements as the arena allows. Old
    // blocks aren't freed, so after 4, 8, ... 64 elements 544 of 1024 bytes
    // are used, and the 512 bytes for 128 elements don't fit
    let mut big: WordVec = {}
    while vecPush(&mut big, big.len as Word) {}
    if big.len != 64 return 17
    if arenaUsed != 544 return 18
    return 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    let f: Word = fixed()
    if f != 0 return f
    let d: Word = dynamic()
    if d != 0 return d
    puts("sizes ok\n")
    return 0
}

// Test directives (m/tests/run.py)
// @output "sizes ok\n"
// @exit 0
