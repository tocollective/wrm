// [2] Loads and stores: a table copied from ROM to RAM, sorted, summed;
// sign and zero extension; the byte order.

import { puts, show, printArray, sort } from "../lib.m"

let NUMBERS: Word[8] = [42, -17, 1000000, 0, -2147483648, 7, 0x7FFFFFFF, -1]

let mut buffer: Word[8]

type SignDemo {
    bytes: UByte[2],
    half:  UHalf,           // offset 2: naturally aligned
}

let SIGN_DEMO: SignDemo = { .bytes = [0x80, 0x7F], .half = 0x8001 }

let demoMemory(): Void {
    puts("\n[2] memory\n")

    // copy the table from ROM to RAM, print it, sort it, print it again
    buffer = NUMBERS
    puts("copied to RAM: ")
    printArray(buffer, 8)
    sort(buffer, 8)
    puts("sorted:        ")
    printArray(buffer, 8)

    // sum it (32-bit wrap-around)
    let mut sum: Word = 0
    for i: UWord in 0..8 sum = sum + buffer[i]
    show("sum", sum as UWord)

    // sign and zero extension: the same bytes through signed and
    // unsigned pointers are LB/LBU and LH/LHU
    let signedByte: *Byte = &SIGN_DEMO.bytes[0] as *Byte
    let signedHalf: *Half = &SIGN_DEMO.half as *Half
    show("LB    0x80", (*signedByte as Word) as UWord)
    show("LBU   0x80", SIGN_DEMO.bytes[0] as UWord)
    show("LH    0x8001", (*signedHalf as Word) as UWord)
    show("LHU   0x8001", SIGN_DEMO.half as UWord)

    // the machine is little-endian
    let mut word: UWord = 0
    let bytes: *mut UByte = &mut word as *mut UByte
    bytes[0] = 0x11
    bytes[1] = 0x22
    bytes[2] = 0x33
    bytes[3] = 0x44
    show("SB 11 22 33 44, LW", word)
    let half: *mut UHalf = &mut word as *mut UHalf
    half[0] = 0xBEEF
    show("SH 0xBEEF, LW", word)
}

export { demoMemory }
