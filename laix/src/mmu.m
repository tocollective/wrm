// Single-CPU MMU manager. All mutations hold memoryLock (save/restore IE).
// Shared supervisor physical window: user code frames become RO here before
// acquiring X anywhere. Task mappings occupy a separate virtual window.
import { kernelRamEnd, MAX_PAGES, PAGE_NONE, PAGE_DIRECTORY, PAGE_TABLE,
    PAGE_USER, PAGE_USER_STACK, allocPage, freePage, physicalPageOwned,
    retainPage, releasePage, physicalPageReferences, pageAccessReferences,
    memoryLock, memoryUnlock } from "memory.m"
import { panic } from "panic.m"
import { PAGE_SIZE, PAGE_MASK, PAGE_TABLE_ENTRIES, SUPERPAGE_SIZE, BOOT_INFO,
    BOOT_INFO_END, BOOT_LOAD, PTE_V, PTE_R, PTE_W, PTE_X, PTE_U, PTE_RWX_BITS,
    PTE_RW, PTE_RX, PTE_RO, CR_PTBR, PTBR_ENABLE, TLBI_ALL, VRAM_BASE, IO_BASE, WORD_BITS } from "defs.m"

let USER_VA_START: UWord = 0x40000000
let USER_VA_END: UWord = 0xC0000000 // exclusive; all other VA belongs to the kernel
let MMU_KERNEL_OWNER: UWord = 0xFFFFFFFF // reserved; never assigned to a task
let PTE_AD: UWord = 0x60 // hardware-maintained A/D, never accepted from callers
let ACCESS_EXEC: UWord = 0x80000000
let ACCESS_COUNT: UWord = 0x7FFFFFFF
extern let kernelStackGuard: UByte
extern let __start_text: UByte
extern let __stop_text: UByte
extern let __start_rodata: UByte
extern let __stop_rodata: UByte
extern let __start_data: UByte
extern let __bss_end: UByte
let mut kernelPageDirectory: *mut UWord
// Only initialized, pinned directories are accepted by the public API.
// The owner already lives in allocator records: only one initialization bit
// per physical frame is needed here, not another full-size owner array.
let mut spaceInitialized: UWord[MAX_PAGES / WORD_BITS]

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

// Overflow-free validation of nonempty page ranges, including the last page.
let mmuUserRangeValid(address: UWord, size: UWord): Bool {
    return address & PAGE_MASK == 0 && size != 0 && size & PAGE_MASK == 0 &&
        address >= USER_VA_START && address < USER_VA_END && size <= USER_VA_END - address
}

let mmuInvalidate(): Void {
    // Also covers inactive ASIDs, permission upgrades and an entire superpage.
    fence()
    tlbi(0, TLBI_ALL)
}

// These operations cannot fail after validation under memoryLock. Treat a
// violated accounting invariant as fatal instead of continuing with stale PTEs.
let mmuRequire(ok: Bool): Void {
    if !ok panic("MMU reference accounting damaged", null)
}

let mmuAllocTable(owner: UWord): UWord {
    let address: UWord = allocPage(owner, PAGE_TABLE)
    if address == PAGE_NONE return PAGE_NONE
    let table: *mut UWord = address as *mut UWord
    for i: UWord in 0..PAGE_TABLE_ENTRIES table[i] = 0
    mmuRequire(retainPage(address, owner, PAGE_TABLE))
    return address
}

let mmuFreeTable(address: UWord, owner: UWord): Void {
    mmuRequire(releasePage(address, owner, PAGE_TABLE))
    mmuRequire(freePage(address, owner, PAGE_TABLE))
}

let mmuInit(): Bool {
    let status: UWord = memoryLock()
    if kernelPageDirectory != null || mfcr(CR_PTBR) & PTBR_ENABLE != 0 ||
        kernelRamEnd == 0 || !kernelLayoutValid() || (&__bss_end as UWord) > kernelRamEnd {
        memoryUnlock(status)
        return false
    }
    let root: UWord = allocPage(MMU_KERNEL_OWNER, PAGE_DIRECTORY)
    if root == PAGE_NONE {
        memoryUnlock(status)
        return false
    }
    let directory: *mut UWord = root as *mut UWord
    for i: UWord in 0..PAGE_TABLE_ENTRIES directory[i] = 0
    let count: UWord = (kernelRamEnd + SUPERPAGE_SIZE - 1) / SUPERPAGE_SIZE
    for i: UWord in 0..count {
        let base: UWord = i * SUPERPAGE_SIZE
        // All RAM uses shared 4 KiB tables, so a physical-window permission
        // change reaches every existing and future space without RW copies.
        let tableAddress: UWord = mmuAllocTable(MMU_KERNEL_OWNER)
        if tableAddress == PAGE_NONE {
            for allocated: UWord in 0..i {
                mmuFreeTable(directory[allocated] & ~PAGE_MASK, MMU_KERNEL_OWNER)
            }
            mmuRequire(freePage(root, MMU_KERNEL_OWNER, PAGE_DIRECTORY))
            memoryUnlock(status)
            return false
        }
        let table: *mut UWord = tableAddress as *mut UWord
        for page: UWord in 0..PAGE_TABLE_ENTRIES {
            let address: UWord = base + page * PAGE_SIZE
            let permissions: UWord = kernelPagePermissions(address)
            if address < kernelRamEnd && permissions != 0 table[page] = address | permissions
        }
        directory[i] = (table as UWord) | PTE_V
    }
    directory[VRAM_BASE / SUPERPAGE_SIZE] = VRAM_BASE | PTE_RW
    directory[IO_BASE / SUPERPAGE_SIZE] = IO_BASE | PTE_RW
    mmuRequire(retainPage(root, MMU_KERNEL_OWNER, PAGE_DIRECTORY))
    kernelPageDirectory = directory
    mmuInvalidate()
    mtcr(CR_PTBR, root | PTBR_ENABLE)
    memoryUnlock(status)
    return true
}

let mmuSpaceOwned(directory: *mut UWord, owner: UWord): Bool {
    let address: UWord = directory as UWord
    let page: UWord = address / PAGE_SIZE
    return kernelPageDirectory != null && owner != MMU_KERNEL_OWNER &&
        physicalPageOwned(address, owner, PAGE_DIRECTORY) &&
        spaceInitialized[page / WORD_BITS] & (1 as UWord << (page % WORD_BITS)) != 0 &&
        physicalPageReferences(address) == 1
}

// Compatibility for creation-time ledgers: a fresh allocated directory only.
let mmuInitAddressSpace(directory: *mut UWord, owner: UWord): Bool {
    let status: UWord = memoryLock()
    let address: UWord = directory as UWord
    let page: UWord = address / PAGE_SIZE
    if kernelPageDirectory == null || mfcr(CR_PTBR) & PTBR_ENABLE == 0 ||
        owner == MMU_KERNEL_OWNER || !physicalPageOwned(address, owner, PAGE_DIRECTORY) ||
        spaceInitialized[page / WORD_BITS] & (1 as UWord << (page % WORD_BITS)) != 0 ||
        physicalPageReferences(address) != 0 ||
        address == (mfcr(CR_PTBR) & ~PAGE_MASK) {
        memoryUnlock(status)
        return false
    }
    for i: UWord in 0..PAGE_TABLE_ENTRIES directory[i] = kernelPageDirectory[i]
    mmuRequire(retainPage(address, owner, PAGE_DIRECTORY))
    spaceInitialized[page / WORD_BITS] |= 1 as UWord << (page % WORD_BITS)
    memoryUnlock(status)
    return true
}

let mmuCreateAddressSpace(owner: UWord): UWord {
    let status: UWord = memoryLock()
    if owner == 0 || owner == MMU_KERNEL_OWNER || kernelPageDirectory == null {
        memoryUnlock(status)
        return PAGE_NONE
    }
    let address: UWord = allocPage(owner, PAGE_DIRECTORY)
    if address != PAGE_NONE && !mmuInitAddressSpace(address as *mut UWord, owner) {
        mmuRequire(freePage(address, owner, PAGE_DIRECTORY))
        memoryUnlock(status)
        return PAGE_NONE
    }
    memoryUnlock(status)
    return address
}

let mmuUserPurpose(address: UWord, owner: UWord): UWord {
    if physicalPageOwned(address, owner, PAGE_USER) return PAGE_USER
    if physicalPageOwned(address, owner, PAGE_USER_STACK) return PAGE_USER_STACK
    return PAGE_NONE
}

let mmuPermissionsValid(permissions: UWord): Bool {
    // Require V/U/R, forbid caller A/D/G/reserved bits and writable code.
    return permissions & (PTE_V | PTE_U | PTE_R) == (PTE_V | PTE_U | PTE_R) &&
        permissions & ~(PTE_V | PTE_U | PTE_RWX_BITS) == 0 &&
        permissions & (PTE_W | PTE_X) != (PTE_W | PTE_X)
}

let mmuPrivateTable(entry: UWord, owner: UWord): Bool {
    return entry & PAGE_MASK == PTE_V && physicalPageOwned(entry & ~PAGE_MASK, owner, PAGE_TABLE) &&
        physicalPageReferences(entry & ~PAGE_MASK) == 1
}

// Remove the old leaf's access from a local count, without changing metadata.
// Only call for an owned frame, under memoryLock.
let mmuAccessRemaining(physical: UWord, previous: UWord): UWord {
    let mut access: UWord = pageAccessReferences[physical / PAGE_SIZE]
    if previous & (PTE_W | PTE_X) != 0 {
        mmuRequire(access & ACCESS_COUNT != 0 &&
            ((access & ACCESS_EXEC != 0) == (previous & PTE_X != 0)))
        access -= 1
        if access & ACCESS_COUNT == 0 access = 0
    }
    return access
}

let mmuAccessValid(physical: UWord, purpose: UWord, permissions: UWord,
    previous: UWord): Bool {
    // A stack is data even if a caller asks for RX instead of RWX.
    if purpose == PAGE_USER_STACK && permissions & PTE_X != 0 return false
    let access: UWord = mmuAccessRemaining(physical, previous)
    if permissions & (PTE_W | PTE_X) == 0 return true
    return access & ACCESS_COUNT != ACCESS_COUNT &&
        (access == 0 || ((access & ACCESS_EXEC != 0) == (permissions & PTE_X != 0)))
}

// Caller has validated conflicts and owns publication/invalidation ordering.
// Return whether the shared physical-window leaf changed. Never give this
// window U or X, and preserve the hardware A/D bits of the identity leaf.
let mmuChangeAccess(physical: UWord, permissions: UWord, previous: UWord): Bool {
    let mut access: UWord = mmuAccessRemaining(physical, previous)
    if permissions & (PTE_W | PTE_X) != 0 {
        access += 1
        if permissions & PTE_X != 0 access |= ACCESS_EXEC
    }
    pageAccessReferences[physical / PAGE_SIZE] = access
    let table: *mut UWord = (kernelPageDirectory[physical / SUPERPAGE_SIZE] & ~PAGE_MASK) as *mut UWord
    let index: UWord = physical / PAGE_SIZE % PAGE_TABLE_ENTRIES
    let mut flags: UWord = PTE_RW
    if access & ACCESS_EXEC != 0 flags = PTE_RO
    let leaf: UWord = physical | flags | (table[index] & PTE_AD)
    if table[index] == leaf return false
    table[index] = leaf
    return true
}

let mapPage(directory: *mut UWord, owner: UWord, virtual: UWord,
    physical: UWord, permissions: UWord): Bool {
    let status: UWord = memoryLock()
    if !mmuSpaceOwned(directory, owner) || !mmuUserRangeValid(virtual, PAGE_SIZE) ||
        !mmuPermissionsValid(permissions) || mmuUserPurpose(physical, owner) == PAGE_NONE {
        memoryUnlock(status)
        return false
    }
    let slot: UWord = virtual / SUPERPAGE_SIZE
    let index: UWord = virtual / PAGE_SIZE % PAGE_TABLE_ENTRIES
    let entry: UWord = directory[slot]
    if entry != 0 && !mmuPrivateTable(entry, owner) {
        memoryUnlock(status)
        return false
    }
    let mut table: *mut UWord = (entry & ~PAGE_MASK) as *mut UWord
    if entry != 0 && table[index] != 0 {
        memoryUnlock(status)
        return false
    }
    let purpose: UWord = mmuUserPurpose(physical, owner)
    if !mmuAccessValid(physical, purpose, permissions, 0) {
        memoryUnlock(status)
        return false
    }
    if !retainPage(physical, owner, purpose) {
        memoryUnlock(status)
        return false
    }
    if entry == 0 {
        let address: UWord = mmuAllocTable(owner)
        if address == PAGE_NONE {
            mmuRequire(releasePage(physical, owner, purpose))
            memoryUnlock(status)
            return false
        }
        table = address as *mut UWord
        // Revoke cached supervisor W before publishing the first executable
        // alias. All fallible work has completed; no rollback can leave RO.
        if mmuChangeAccess(physical, permissions, 0) mmuInvalidate()
        table[index] = physical | permissions
        fence() // initialize the entire table before publishing the parent
        directory[slot] = address | PTE_V
    } else {
        if mmuChangeAccess(physical, permissions, 0) mmuInvalidate()
        table[index] = physical | permissions
    }
    mmuInvalidate()
    memoryUnlock(status)
    return true
}

let mmuUserLeaf(directory: *mut UWord, owner: UWord, virtual: UWord): UWord {
    if !mmuSpaceOwned(directory, owner) || !mmuUserRangeValid(virtual, PAGE_SIZE) return 0
    let entry: UWord = directory[virtual / SUPERPAGE_SIZE]
    if !mmuPrivateTable(entry, owner) return 0
    let table: *UWord = (entry & ~PAGE_MASK) as *UWord
    let leaf: UWord = table[virtual / PAGE_SIZE % PAGE_TABLE_ENTRIES]
    if !mmuPermissionsValid((leaf & PAGE_MASK) & ~PTE_AD) ||
        mmuUserPurpose(leaf & ~PAGE_MASK, owner) == PAGE_NONE ||
        physicalPageReferences(leaf & ~PAGE_MASK) == 0 return 0
    return leaf
}

let unmapPage(directory: *mut UWord, owner: UWord, virtual: UWord): Bool {
    let status: UWord = memoryLock()
    let leaf: UWord = mmuUserLeaf(directory, owner, virtual)
    if leaf == 0 {
        memoryUnlock(status)
        return false
    }
    let slot: UWord = virtual / SUPERPAGE_SIZE
    let address: UWord = directory[slot] & ~PAGE_MASK
    let table: *mut UWord = address as *mut UWord
    table[virtual / PAGE_SIZE % PAGE_TABLE_ENTRIES] = 0
    let mut empty: Bool = true
    for i: UWord in 0..PAGE_TABLE_ENTRIES {
        if table[i] != 0 empty = false
    }
    if empty directory[slot] = 0
    mmuInvalidate() // invalidate before returning any physical frame
    let physical: UWord = leaf & ~PAGE_MASK
    // The user translation is gone from all ASIDs before restoring kernel W.
    if mmuChangeAccess(physical, 0, leaf) mmuInvalidate()
    mmuRequire(releasePage(physical, owner, mmuUserPurpose(physical, owner)))
    if empty mmuFreeTable(address, owner)
    // The leaf remains owned: the caller may remap it or freePage it now.
    memoryUnlock(status)
    return true
}

let setPagePermissions(directory: *mut UWord, owner: UWord, virtual: UWord,
    permissions: UWord): Bool {
    let status: UWord = memoryLock()
    let leaf: UWord = mmuUserLeaf(directory, owner, virtual)
    if leaf == 0 || !mmuPermissionsValid(permissions) {
        memoryUnlock(status)
        return false
    }
    let physical: UWord = leaf & ~PAGE_MASK
    if !mmuAccessValid(physical, mmuUserPurpose(physical, owner), permissions, leaf) {
        memoryUnlock(status)
        return false
    }
    let table: *mut UWord = (directory[virtual / SUPERPAGE_SIZE] & ~PAGE_MASK) as *mut UWord
    let index: UWord = virtual / PAGE_SIZE % PAGE_TABLE_ENTRIES
    if ((leaf & (PTE_W | PTE_X)) != (permissions & (PTE_W | PTE_X))) {
        // Break before make: no stale user X when kernel W is restored, and
        // no stale user/kernel W when the replacement becomes executable.
        table[index] = 0
        mmuInvalidate()
        if mmuChangeAccess(physical, permissions, leaf) mmuInvalidate()
    }
    table[index] = physical | permissions | (leaf & PTE_AD)
    mmuInvalidate()
    memoryUnlock(status)
    return true
}

// Split a task's inherited supervisor superpage into a private table, keeping
// every physical address and permission. Shared kernel tables are untouched.
// RAM already uses shared tables and cannot be split into stale RW copies.
// Kernel mappings cannot be edited through map/unmap/permission APIs.
let mmuSplitSuperpage(directory: *mut UWord, owner: UWord, virtual: UWord): Bool {
    let status: UWord = memoryLock()
    if !mmuSpaceOwned(directory, owner) || virtual & PAGE_MASK != 0 ||
        (virtual >= USER_VA_START && virtual < USER_VA_END) {
        memoryUnlock(status)
        return false
    }
    let slot: UWord = virtual / SUPERPAGE_SIZE
    let entry: UWord = directory[slot]
    // A/D may have been set in only one of the directories by the CPU.
    if entry & PTE_RWX_BITS == 0 || (entry & ~PTE_AD) != (kernelPageDirectory[slot] & ~PTE_AD) {
        memoryUnlock(status)
        return false
    }
    let address: UWord = mmuAllocTable(owner)
    if address == PAGE_NONE {
        memoryUnlock(status)
        return false
    }
    let table: *mut UWord = address as *mut UWord
    let base: UWord = entry & ~(SUPERPAGE_SIZE - 1)
    for i: UWord in 0..PAGE_TABLE_ENTRIES table[i] = (base + i * PAGE_SIZE) | (entry & PAGE_MASK)
    fence()
    directory[slot] = address | PTE_V
    mmuInvalidate()
    memoryUnlock(status)
    return true
}

let mmuSwitchAddressSpace(directory: *mut UWord, owner: UWord, asid: UWord): Bool {
    let status: UWord = memoryLock()
    if !mmuSpaceOwned(directory, owner) || asid > 255 {
        memoryUnlock(status)
        return false
    }
    fence()
    // Invalidate BEFORE a different-ASID PTBR can fetch a stale translation.
    // This deliberately forgoes ASID caching; no separate ASID lease registry.
    tlbi(0, TLBI_ALL)
    mtcr(CR_PTBR, (directory as UWord) | (asid << 4) | PTBR_ENABLE)
    memoryUnlock(status)
    return true
}

let mmuActivateKernel(): Bool {
    let status: UWord = memoryLock()
    if kernelPageDirectory == null {
        memoryUnlock(status)
        return false
    }
    fence()
    tlbi(0, TLBI_ALL)
    mtcr(CR_PTBR, (kernelPageDirectory as UWord) | PTBR_ENABLE)
    memoryUnlock(status)
    return true
}

// Trusted kernel owns table contents. Validate all private tables/leaves before
// teardown so wrong ownership cannot produce partial destruction.
let mmuDestroyAddressSpace(directory: *mut UWord, owner: UWord): Bool {
    let status: UWord = memoryLock()
    let root: UWord = directory as UWord
    if !mmuSpaceOwned(directory, owner) || root == (mfcr(CR_PTBR) & ~PAGE_MASK) {
        memoryUnlock(status)
        return false
    }
    for slot: UWord in 0..PAGE_TABLE_ENTRIES {
        let entry: UWord = directory[slot]
        if ((entry & ~PTE_AD) == (kernelPageDirectory[slot] & ~PTE_AD)) continue
        if !mmuPrivateTable(entry, owner) {
            memoryUnlock(status)
            return false
        }
        if slot >= USER_VA_START / SUPERPAGE_SIZE && slot < USER_VA_END / SUPERPAGE_SIZE {
            let table: *UWord = (entry & ~PAGE_MASK) as *UWord
            for i: UWord in 0..PAGE_TABLE_ENTRIES {
                if table[i] != 0 && mmuUserLeaf(directory, owner, slot * SUPERPAGE_SIZE + i * PAGE_SIZE) == 0 {
                    memoryUnlock(status)
                    return false
                }
            }
        }
    }
    // Detach private parents, retaining their addresses in invalid entries for
    // the release pass. Flush AFTER this change and BEFORE freeing any frame.
    // The root is inactive and cannot be activated while memoryLock is held.
    for slot: UWord in 0..PAGE_TABLE_ENTRIES {
        let entry: UWord = directory[slot]
        if ((entry & ~PTE_AD) == (kernelPageDirectory[slot] & ~PTE_AD)) continue
        directory[slot] = entry & ~PTE_V
    }
    mmuInvalidate()
    let mut windowChanged: Bool = false
    for slot: UWord in 0..PAGE_TABLE_ENTRIES {
        let entry: UWord = directory[slot]
        if ((entry & ~PTE_AD) == (kernelPageDirectory[slot] & ~PTE_AD)) continue
        let address: UWord = entry & ~PAGE_MASK
        let table: *mut UWord = address as *mut UWord
        directory[slot] = 0
        if slot >= USER_VA_START / SUPERPAGE_SIZE && slot < USER_VA_END / SUPERPAGE_SIZE {
            for i: UWord in 0..PAGE_TABLE_ENTRIES {
                let physical: UWord = table[i] & ~PAGE_MASK
                if table[i] == 0 continue
                let purpose: UWord = mmuUserPurpose(physical, owner)
                if mmuChangeAccess(physical, 0, table[i]) windowChanged = true
                table[i] = 0
                mmuRequire(releasePage(physical, owner, purpose))
                // Multiple aliases/spaces retain the frame until the last one.
                if physicalPageReferences(physical) == 0 mmuRequire(freePage(physical, owner, purpose))
            }
        }
        mmuFreeTable(address, owner)
    }
    if windowChanged mmuInvalidate()
    let page: UWord = root / PAGE_SIZE
    spaceInitialized[page / WORD_BITS] &= ~(1 as UWord << (page % WORD_BITS))
    mmuRequire(releasePage(root, owner, PAGE_DIRECTORY))
    mmuRequire(freePage(root, owner, PAGE_DIRECTORY))
    memoryUnlock(status)
    return true
}

export { USER_VA_START, USER_VA_END, mmuUserRangeValid, mmuInit,
    mmuInitAddressSpace, mmuCreateAddressSpace, mapPage, unmapPage,
    setPagePermissions, mmuSplitSuperpage, mmuSwitchAddressSpace,
    mmuActivateKernel, mmuDestroyAddressSpace }
