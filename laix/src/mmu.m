// Initial supervisor identity map. General kernel W^X and task address
// spaces are later stages; this map makes the stack guard inaccessible now.
import { kernelRamEnd } from "memory.m"
import { PAGE_SIZE, PAGE_MASK, PAGE_TABLE_ENTRIES, SUPERPAGE_SIZE,
    PTE_V, PTE_RW, PTE_RWX, CR_PTBR, PTBR_ENABLE, TLBI_ALL, VRAM_BASE, IO_BASE } from "defs.m"

extern let kernelStackGuard: UByte
align(PAGE_SIZE) let mut kernelPageDirectory: UWord[PAGE_TABLE_ENTRIES]
align(PAGE_SIZE) let mut kernelGuardTable: UWord[PAGE_TABLE_ENTRIES]
align(PAGE_SIZE) let mut kernelTailTable: UWord[PAGE_TABLE_ENTRIES]

let mmuInit(): Bool {
    // Called exactly once, after memoryInit and before any free-page use.
    if mfcr(CR_PTBR) & PTBR_ENABLE != 0 || kernelRamEnd == 0 return false
    let guard: UWord = &kernelStackGuard as UWord
    if guard & PAGE_MASK != 0 || guard >= kernelRamEnd return false
    for i: UWord in 0..PAGE_TABLE_ENTRIES {
        kernelPageDirectory[i] = 0
        kernelGuardTable[i] = 0
        kernelTailTable[i] = 0
    }
    let count: UWord = (kernelRamEnd + SUPERPAGE_SIZE - 1) / SUPERPAGE_SIZE
    for i: UWord in 0..count {
        let base: UWord = i * SUPERPAGE_SIZE
        if i != guard / SUPERPAGE_SIZE && base + SUPERPAGE_SIZE <= kernelRamEnd {
            kernelPageDirectory[i] = base | PTE_RWX
            continue
        }
        // At most two split regions: the guard and the incomplete RAM tail.
        // When they coincide, use the guard table for both.
        let mut table: *mut UWord = &mut kernelTailTable[0]
        if i == guard / SUPERPAGE_SIZE table = &mut kernelGuardTable[0]
        for page: UWord in 0..PAGE_TABLE_ENTRIES {
            let address: UWord = base + page * PAGE_SIZE
            if address < kernelRamEnd && address != guard {
                table[page] = address | PTE_RWX
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

export { mmuInit }
