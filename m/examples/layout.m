// Struct layout is the same as in C (ABI, "Data types"):
//   - fields go in the order they are written, the compiler never reorders them
//   - each field is aligned to its own alignment
//   - the size is a multiple of the largest alignment
//
// sizeof(T), alignof(T), offsetof(T, field) are compile-time constants.
// There are no bit fields: flags are constants with '|', '&' and '<<'.
//
// 'packed type' has no padding: fields follow each other, the alignment is 1.
// Unaligned fields are read and written byte by byte, because an unaligned
// LW is an exception. Taking the address of an unaligned field is an error.
//
// 'align(N)' before a global variable aligns it to N bytes (a power of two).
// Local variables cannot have it: sp is aligned only to 8.

type Color {
    r: UByte,  // offset 0
    g: UByte,  // offset 1
    b: UByte,  // offset 2
}              // size 3, align 1

type Header {
    kind:   UByte,  // offset 0, then 3 bytes of padding
    length: UWord,  // offset 4
    flags:  UHalf,  // offset 8, then 2 bytes of padding
}                   // size 12, align 4

// Saved registers, shared with the assembly trap entry: the order matters
type TrapFrame {
    regs:   UWord[31],  // offset 0, r1..r31
    epc:    UWord,      // offset 124
    status: UWord,      // offset 128
    cause:  UWord,      // offset 132
}                       // size 136, align 4

// The same fields without padding, e.g. a header read from a disk
packed type DiskHeader {
    kind:   UByte,  // offset 0
    length: UWord,  // offset 1: unaligned
    flags:  UHalf,  // offset 5: unaligned
}                   // size 7, align 1

let diskLength(h: *DiskHeader): UWord {
    // Compiled as four LBU and shifts, not one LW
    return h.length
}

let diskKind(h: *DiskHeader): *UByte {
    // 'kind' is at offset 0 and is a UByte, so its address is fine
    return &h.kind
    // Compile error: 'length' is not aligned, LW through this pointer would fail
    //     let p: *UWord = &h.length
}

// The page directory: PTBR needs a 4096-byte aligned address
align(4096) let mut pageDir: UWord[1024]

let enablePaging(): Void {
    mtcr(6, &pageDir as UWord)  // 6 is PTBR

    // Compile error: 'align' only on global variables
    //     align(16) let mut local: UByte[64]
}

let HEADER_SIZE: UWord      = sizeof(Header)              // 12
let DISK_HEADER_SIZE: UWord = sizeof(DiskHeader)          // 7
let DISK_HEADER_ALIGN: UWord = alignof(DiskHeader)        // 1
let HEADER_ALIGN: UWord     = alignof(Header)             // 4
let COLOR_SIZE: UWord       = sizeof(Color)               // 3
let FRAME_SIZE: UWord       = sizeof(TrapFrame)           // 136
let FRAME_EPC: UWord        = offsetof(TrapFrame, epc)    // 124
let HEADER_LENGTH: UWord    = offsetof(Header, length)    // 4

// Page table entry flags (INSTRUCTIONS, "Page tables")
let PTE_V: UWord = 1 << 0
let PTE_R: UWord = 1 << 1
let PTE_W: UWord = 1 << 2
let PTE_X: UWord = 1 << 3
let PTE_U: UWord = 1 << 4
let PTE_A: UWord = 1 << 5
let PTE_D: UWord = 1 << 6
let PTE_G: UWord = 1 << 7

let PTE_ADDR_MASK: UWord = 0xFFFF_F000

let makePte(physAddr: UWord, flags: UWord): UWord {
    return physAddr & PTE_ADDR_MASK | flags | PTE_V
}

let isWritable(pte: UWord): Bool {
    return pte & PTE_W != 0
}

let pteAddress(pte: UWord): UWord {
    return pte & PTE_ADDR_MASK
}

let main(argc: UWord, argv: *UByte[]): Word {
    let code: UWord = makePte(0x0001_0000, PTE_R | PTE_X)
    let data: UWord = makePte(0x0002_0000, PTE_R | PTE_W | PTE_U)
    let w: Bool = isWritable(data)  // true
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
