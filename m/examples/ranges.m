// Ranges in 'for':
//   a..b   half-open, 'b' is excluded
//   a...b  closed, 'b' is included
// Both bounds are evaluated once, before the first iteration.
// If the range is empty (a >= b for '..', a > b for '...'), the body never runs.

import { puts } from "externs.m"

let printArgs(argc: UWord, argv: *UByte[]): Void {
    // argc = 0 gives zero iterations, no 'argc - 1' underflow
    for i: UWord in 0..argc {
        puts(argv[i])
        puts("\n")
    }
}

let printEveryOtherArg(argc: UWord, argv: *UByte[]): Void {
    // 'for mut' variable can be changed in the body, and the change
    // affects the loop, like in C. Here every second argument is skipped.
    // Same as:
    //     let mut i: UWord = 0
    //     while i < argc { ...body... i++ }
    for mut i: UWord in 0..argc {
        puts(argv[i])
        puts("\n")
        i++
    }
}

let countAllBytes(): UWord {
    // Closed range up to the maximum value of the type: 256 iterations.
    // The loop stops after i = 0xFF, so 'i' never wraps around to 0.
    let mut count: UWord = 0
    for i: UByte in 0...0xFF {
        count++
    }
    return count
}

let printDigits(): Void {
    // 'i' without 'mut' cannot be assigned: 'i = 5' here is a compile error
    for i: UWord in 0...9 {
        puts("digit\n")
    }
}

// Step: 'by' followed by a non-zero integer constant. Without 'by' the step is 1.
// The sign of the step gives the direction, so a negative step counts down
// even for an unsigned variable. The loop never steps past the end.

let printEvenDigits(): Void {
    // 0, 2, 4, 6, 8
    for i: UWord in 0...9 by 2 {
        puts("even\n")
    }
}

let printArgsBackwards(argc: UWord, argv: *UByte[]): Void {
    // i = argc, ..., 2, 1: the end (0) is excluded, so the index is 'i - 1'.
    // argc = 0 gives zero iterations. 'argc - 1 ... 0 by -1' would bring back
    // the underflow from the first version of example.m.
    for i: UWord in argc..0 by -1 {
        puts(argv[i - 1])
        puts("\n")
    }
}

let countdown(): Void {
    // 10, 9, ..., 1, 0 (closed range counting down)
    for i: UWord in 10...0 by -1 {
        puts("tick\n")
    }

    // 0xFF, 0xFC, ..., 0x03, 0x00: stops at 0, 'i' never wraps around
    for i: UByte in 0xFF...0 by -3 {
        puts("tock\n")
    }
}

// Compile errors:
//     for i: UWord in 0...9 by 0 {}       // zero step
//     for i: UWord in 0...9 by n {}       // step is not a constant
//     for i: UByte in 0...9 by 300 {}     // step does not fit in UByte

let main(argc: UWord, argv: *UByte[]): Word {
    printArgs(argc, argv)
    printEveryOtherArg(argc, argv)
    printDigits()
    printEvenDigits()
    printArgsBackwards(argc, argv)
    countdown()

    let n: UWord = countAllBytes()  // 256
    return 0
}

// Test directives (m/tests/run.py)
// @output "digit\n" * 10
// @output "even\n" * 5
// @output "tick\n" * 11
// @output "tock\n" * 86
// @exit 0
