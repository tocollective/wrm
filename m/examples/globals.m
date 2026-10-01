// Global variables:
//   - the initializer must be a constant expression: literals, arithmetic on
//     them, other global 'let' constants, 'as' of a constant, '{ ... }' of
//     constants, the address of another global or of a function
//   - calling a function in a global initializer is an error: nothing runs
//     before 'main'
//   - a global 'let mut' without '=' is in .bss and starts as zeros
//
// Where they go:
//   let X: T = constant            .rodata (or nowhere, if the address is never taken)
//   let mut X: T = constant != 0   .data
//   let mut X: T = 0, or no '='    .bss

import { puts } from "externs.m"

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

type UartRegs {
    data:    UWord,
    status:  UWord,
    control: UWord,
}

// Constants
let PAGE_SIZE: UWord = 4096
let PAGE_MASK: UWord = PAGE_SIZE - 1            // another constant
let STATUS_IE: UWord = 1 << 0
let RED: Color = { .r = 0xFF }                  // .g and .b are zero
let GREETING: *UByte = "Hello, M!\n"            // address of a string in .rodata

// 'as' of a constant: a fixed address (device registers need 'volatile', see mmio.m)
let uart: *volatile mut UartRegs = 0xFD00_2000 as *volatile mut UartRegs

// Mutable globals
let mut ticks: UWord                            // .bss: starts as 0
let mut current: Color = { .g = 0xFF }          // .data
let mut screen: UByte[4000]                     // .bss: 4000 zero bytes

let tick(): Void {
    ticks++
}

// The address of another global and of a function
let currentPtr: *mut Color = &mut current
let onTick: (): Void = tick

// Symbols defined by the linker script: only their address matters
extern let __bss_start: UByte
extern let __bss_end: UByte

let bssSize(): UWord {
    return (&__bss_end as UWord) - (&__bss_start as UWord)
}

// Compile errors: not a constant expression
//     let START: UWord = ticks          // 'ticks' is 'let mut'
//     let BLUE: Color = makeBlue()      // function call

let main(argc: UWord, argv: *UByte[]): Word {
    puts(GREETING)
    onTick()
    currentPtr.r = 0x80
    let page: UWord = 0x1234 & ~PAGE_MASK         // 0x1000
    let bss: UWord = bssSize()
    return 0
}

// Test directives (m/tests/run.py)
// @output "Hello, M!\n"
// @exit 0
