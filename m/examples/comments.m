// Comments:
//   //   to the end of the line
//   /**/ block comments; they nest, like in Rust
//   ///  a doc comment: goes right before a declaration and describes it

import { puts } from "externs.m"

/// A color with 8 bits per channel.
type Color {
    /// Red, 0x00..0xFF.
    r: UByte,
    /// Green, 0x00..0xFF.
    g: UByte,
    /// Blue, 0x00..0xFF.
    b: UByte,
}

/// Number of times 'greet' was called.
let mut greetings: UWord

/// Prints a greeting and counts it.
///
/// 'name' must be a zero-terminated string.
let greet(name: *UByte): Void {
    puts("Hello, ")
    puts(name)  // the name is printed as is
    puts("!\n")
    greetings++
}

/*
   A block comment can span lines.

   Block comments nest, so code with a comment inside can be commented out:

   /* the old version */
   let greetOld(name: *UByte): Void {
       puts(name)  /* no greeting */
   }
*/

let main(argc: UWord, argv: *UByte[]): Word {
    greet(/* inside an expression too */ "M")
    return 0
}

// Test directives (m/tests/run.py)
// @output "Hello, M!\n"
// @exit 0
