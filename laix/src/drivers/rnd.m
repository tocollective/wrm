import { RNG_BASE, RNG_SEEDED, WORD_BYTES, BYTE_BITS } from "../arch/wrm081632/defs.m"
// WRM RNG MMIO: DATA consumes a fresh word on every read; STATUS does not.
// No initialization, polling, interrupts or register writes are needed.
type RngRegs {
    data: UWord,
    status: UWord,
}

let rng: *volatile RngRegs = RNG_BASE as *volatile RngRegs

let rngWord(): UWord {
    return rng.data
}

// True for --seed / --deterministic: these values are reproducible, not secret.
let rngSeeded(): Bool {
    return rng.status & RNG_SEEDED != 0
}

// Writes exactly size bytes, low byte first; the buffer need not be aligned.
// Each group of up to four bytes consumes one DATA word. Unused high bytes
// of the final word are discarded, with no software cache across calls.
// A zero-sized request succeeds even with null and consumes no random data.
// For a nonempty request, the caller supplies size writable bytes of RAM.
let rngFill(buffer: mut UByte[], size: UWord): Bool {
    if size == 0 return true
    if buffer == null return false
    let mut offset: UWord = 0
    while offset < size {
        let mut value: UWord = rngWord()
        let mut count: UWord = size - offset
        if count > WORD_BYTES count = WORD_BYTES
        for i: UWord in 0..count {
            buffer[offset] = value as UByte
            value >>= BYTE_BITS
            offset++
        }
    }
    return true
}

export { rngWord, rngSeeded, rngFill }
