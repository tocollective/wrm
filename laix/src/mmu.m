// Supervisor identity map shared by task directories, with kernel W^X:
// code RX, read-only data R, everything else RW and never executable.
// Page zero (NULL), the stack guard and the old firmware stack are unmapped.
// User mappings are a later stage.
import { kernelRamEnd, physicalPageAvailable } from "memory.m"
import { PAGE_SIZE, PAGE_MASK, PAGE_TABLE_ENTRIES, SUPERPAGE_SIZE, BOOT_INFO,
    BOOT_INFO_END, BOOT_LOAD, PTE_V, PTE_RW, PTE_RX, PTE_RO, CR_PTBR, PTBR_ENABLE,
    TLBI_ALL, VRAM_BASE, IO_BASE } from "defs.m"

extern let kernelStackGuard: UByte
// start.asm page-aligns .rodata and .data, so each section owns its pages.
extern let __start_text: UByte
extern let __stop_text: UByte
extern let __start_rodata: UByte
extern let __stop_rodata: UByte
extern let __start_data: UByte
extern let __bss_end: UByte
align(PAGE_SIZE) let mut kernelPageDirectory: UWord[PAGE_TABLE_ENTRIES]
align(PAGE_SIZE) let mut kernelLowTable: UWord[PAGE_TABLE_ENTRIES]
align(PAGE_SIZE) let mut kernelTailTable: UWord[PAGE_TABLE_ENTRIES]

// The kernel image, BSS and the guard lie in the first superpage, which
// kernelLowTable maps page by page.
let kernelLayoutValid(): Bool {
    let textStart: UWord = &__start_text as UWord
    let rodataStart: UWord = &__start_rodata as UWord
    let dataStart: UWord = &__start_data as UWord
    let guard: UWord = &kernelStackGuard as UWord
    return textStart == BOOT_LOAD && rodataStart & PAGE_MASK == 0 &&
        dataStart & PAGE_MASK == 0 && (&__stop_text as UWord) <= rodataStart &&
        (&__stop_rodata as UWord) <= dataStart && rodataStart <= dataStart &&
        guard & PAGE_MASK == 0 && guard >= dataStart &&
        guard + PAGE_SIZE <= (&__bss_end as UWord) && (&__bss_end as UWord) <= SUPERPAGE_SIZE
}

// Kernel PTE permissions of a RAM page, 0 when it stays unmapped.
let kernelPagePermissions(address: UWord): UWord {
    // Page zero: a NULL load, store or call faults.
    if address < BOOT_INFO return 0
    // Boot info and the trap entry state.
    if address < BOOT_INFO_END return PTE_RW
    // The firmware's stack: unused once start.asm switches stacks.
    if address < BOOT_LOAD return 0
    if address < (&__start_rodata as UWord) return PTE_RX
    if address < (&__start_data as UWord) return PTE_RO
    if address == (&kernelStackGuard as UWord) return 0
    return PTE_RW
}

let mmuInit(): Bool {
    // Called exactly once, after memoryInit and before any free-page use.
    if mfcr(CR_PTBR) & PTBR_ENABLE != 0 || kernelRamEnd == 0 return false
    if !kernelLayoutValid() || (&__bss_end as UWord) > kernelRamEnd return false
    for i: UWord in 0..PAGE_TABLE_ENTRIES {
        kernelPageDirectory[i] = 0
        kernelLowTable[i] = 0
        kernelTailTable[i] = 0
    }
    let count: UWord = (kernelRamEnd + SUPERPAGE_SIZE - 1) / SUPERPAGE_SIZE
    for i: UWord in 0..count {
        let base: UWord = i * SUPERPAGE_SIZE
        if i != 0 && base + SUPERPAGE_SIZE <= kernelRamEnd {
            kernelPageDirectory[i] = base | PTE_RW
            continue
        }
        // At most two split regions: the kernel's and the incomplete RAM
        // tail. When they coincide, the low table serves both.
        let mut table: *mut UWord = &mut kernelTailTable[0]
        if i == 0 table = &mut kernelLowTable[0]
        for page: UWord in 0..PAGE_TABLE_ENTRIES {
            let address: UWord = base + page * PAGE_SIZE
            let permissions: UWord = kernelPagePermissions(address)
            if address < kernelRamEnd && permissions != 0 {
                table[page] = address | permissions
            }
        }
        kernelPageDirectory[i] = (table as UWord) | PTE_V
    }
    // The console copies glyphs to VRAM; UART, disks and power use MMIO.
    // No U, X or G bits in device mappings, and no alias of the guard frame.
    kernelPageDirectory[VRAM_BASE / SUPERPAGE_SIZE] = VRAM_BASE | PTE_RW
    kernelPageDirectory[IO_BASE / SUPERPAGE_SIZE] = IO_BASE | PTE_RW
    fence()
    tlbi(0, TLBI_ALL)
    mtcr(CR_PTBR, (&kernelPageDirectory[0] as UWord) | PTBR_ENABLE)
    return true
}

// Initialize an owned, inactive physical directory page before adding user
// mappings. Every address space inherits the same supervisor entry code,
// low stack-switch state, kernel stacks/data, page tables and panic devices.
// Shared kernel tables and nonzero directory slots must remain immutable;
// user mappings belong only in the remaining slots. RAM has no U aliases here,
// and page zero stays unmapped.
// The caller must fence and invalidate the TLB before activating the directory.
let mmuInitAddressSpace(directory: *mut UWord): Bool {
    let address: UWord = directory as UWord
    if mfcr(CR_PTBR) & PTBR_ENABLE == 0 || !physicalPageAvailable(address) ||
        address == (mfcr(CR_PTBR) & ~PAGE_MASK) return false
    for i: UWord in 0..PAGE_TABLE_ENTRIES {
        directory[i] = kernelPageDirectory[i]
    }
    return true
}

export { mmuInit, mmuInitAddressSpace }
