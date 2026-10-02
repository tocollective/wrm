// Runtime regression using the ChaCha20 zero-key/zero-nonce test vector.
// @args --seed=0
// @exit 0
import { rngWord, rngSeeded, rngFill } from "../src/rnd.m"

let main(argc: UWord, argv: *UByte[]): Word {
    if !rngSeeded() || !rngSeeded() return 1
    if !rngFill(null, 0) || rngFill(null, 1) return 2
    if rngWord() != 0xADE0B876 return 3

    // Requests of 1, 2, 3, 4 and 5 bytes consume words 1 through 6.
    let expected: UByte[15] = [
        0xA0,
        0x40, 0x5D,
        0x53, 0x86, 0xBD,
        0xBD, 0xD2, 0x19, 0xB8,
        0xA0, 0x8D, 0xED, 0x1A, 0xA8,
    ]
    let mut buffer: UByte[7]
    let mut offset: UWord = 0
    for size: UWord in 1..6 {
        for i: UWord in 0..7 buffer[i] = 0xCC
        if !rngFill(&mut buffer[1], size) return 4
        if buffer[0] != 0xCC return 5
        for i: UWord in 0..size {
            if buffer[i + 1] != expected[offset + i] return 6
        }
        for i: UWord in (size + 1)..7 {
            if buffer[i] != 0xCC return 7
        }
        offset += size
    }
    if !rngFill(&mut buffer[0], 0) return 8
    if rngWord() != 0xC70D778B return 9

    // Consume the rest of the first block and cross the device pool boundary.
    let tail: UByte[32] = [
        0xDA, 0x41, 0x59, 0x7C, 0x51, 0x57, 0x48, 0x8D,
        0x77, 0x24, 0xE0, 0x3F, 0xB8, 0xD8, 0x4A, 0x37,
        0x6A, 0x43, 0xB8, 0xF4, 0x15, 0x18, 0xA1, 0x1C,
        0xC3, 0x87, 0xB6, 0x69, 0xB2, 0xEE, 0x65, 0x86,
    ]
    let mut block: UByte[32]
    if !rngFill(block, 32) return 10
    for i: UWord in 0..32 {
        if block[i] != tail[i] return 11
    }
    if rngWord() != 0xBEE7079F return 12
    return 0
}
