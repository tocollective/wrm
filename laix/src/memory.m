// Bootstrap physical-page accounting. The future allocator must only seed
// its free list with pages accepted by physicalPageAvailable().
import { PAGE_MASK, RAM_MAX_BYTES } from "defs.m"
extern let __bss_end: UByte
let mut kernelReservedEnd: UWord
let mut kernelRamEnd: UWord

let memoryInit(ramSize: UWord): Bool {
    // The machine supports up to four 32 MiB RAM slots. Bound arithmetic
    // before rounding and reject a BSS that occupies an incomplete page.
    if ramSize == 0 || ramSize > RAM_MAX_BYTES return false
    let usedEnd: UWord = &__bss_end as UWord
    if usedEnd > ramSize return false
    let reservedEnd: UWord = (usedEnd + PAGE_MASK) & ~PAGE_MASK
    let ramEnd: UWord = ramSize & ~PAGE_MASK
    if reservedEnd > ramEnd return false
    // Reserve low firmware/boot memory (including the entry-state words),
    // the loaded image and ALL BSS,
    // including the guard page, kernel stack and bootstrap page tables.
    kernelReservedEnd = reservedEnd
    kernelRamEnd = ramEnd
    return true
}

let physicalPageAvailable(address: UWord): Bool {
    return kernelRamEnd != 0 && address & PAGE_MASK == 0 &&
        address >= kernelReservedEnd && address < kernelRamEnd
}

export { kernelReservedEnd, kernelRamEnd,
    memoryInit, physicalPageAvailable }
