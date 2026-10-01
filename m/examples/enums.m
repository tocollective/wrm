// enum:
//   - has an integer base type: 'enum Cause: UWord { ... }'
//   - values work like in C: the first member without '=' is 0, every next
//     member without '=' is the previous one plus 1; an explicit value can be
//     given to any member, and counting goes on from it
//   - members are written with the type name: 'Cause.Syscall'
//   - converts to and from the base type only with 'as'
//   - converting back is not checked: an enum can hold a value that is not
//     in the list, like in C
//   - two members with the same value are an error
//   - size and alignment are those of the base type

import { puts } from "externs.m"

// The values must match the CPU (INSTRUCTIONS, "Exceptions"). They go
// in a row from 0, so no '=' is needed.
enum Cause: UWord {
    Interrupt,           // 0
    IllegalInstruction,  // 1
    MisalignedFetch,     // 2
    MisalignedLoad,      // 3
    MisalignedStore,     // 4
    FetchBusError,       // 5
    LoadBusError,        // 6
    StoreBusError,       // 7
    FetchPageFault,      // 8
    LoadPageFault,       // 9
    StorePageFault,      // 10
    Privileged,          // 11
    Syscall,             // 12
}

// A small base type is enough for a small set
enum Direction: UByte {
    Up,     // 0
    Down,   // 1
    Left,   // 2
    Right,  // 3
}

// Gaps: counting goes on from the last explicit value
enum Key: UByte {
    None,          // 0
    Escape,        // 1
    Enter,         // 2
    Backspace,     // 3
    F1 = 0x70,     // 0x70
    F2,            // 0x71
    F3,            // 0x72
    Up = 0x80,     // 0x80
    Down,          // 0x81
}

let CR_CAUSE: UWord = 4

let currentCause(): Cause {
    // From the base type: 'as'
    return mfcr(CR_CAUSE) as Cause
}

let isPageFault(c: Cause): Bool {
    return c == Cause.FetchPageFault
        || c == Cause.LoadPageFault
        || c == Cause.StorePageFault
}

let opposite(d: Direction): Direction {
    if d == Direction.Up return Direction.Down
    if d == Direction.Down return Direction.Up
    if d == Direction.Left return Direction.Right
    return Direction.Left
}

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Cause = currentCause()
    if isPageFault(c) puts("page fault\n")

    // To the base type: 'as'
    let code: UWord = c as UWord

    let d: Direction = opposite(Direction.Left)  // Direction.Right
    let size: UWord = sizeof(Direction)          // 1
    let f2: UByte = Key.F2 as UByte              // 0x71

    // Not checked: 'odd' holds 7, which is not in the list
    let odd: Direction = 7 as Direction

    // Compile errors:
    //     let n: UWord = c                       // no implicit conversion
    //     let e: Cause = 12                      // no implicit conversion
    //     let s: Cause = Syscall                 // the type name is required
    //     enum Bad: UByte { A = 1, B = 1 }       // same value twice
    //     enum Bad2: UByte { A, B, C = 1 }       // C = 1 is B again
    //     enum Big: UByte { A = 255, B }         // B would be 256
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
