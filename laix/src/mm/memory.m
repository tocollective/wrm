// Physical 4 KiB frames. Only the small bitmap lives in BSS. Ownership and
// reference records are sized to installed RAM and reserved just after BSS
// before any frame is made available to the allocator.
import { PAGE_SIZE, PAGE_MASK, WORD_BYTES, WORD_BITS, RAM_MAX_BYTES,
    CR_STATUS, STATUS_IE } from "../arch/wrm081632/defs.m"
extern let __bss_end: UByte
let MAX_PAGES: UWord = RAM_MAX_BYTES / PAGE_SIZE
let BITMAP_WORDS: UWord = MAX_PAGES / WORD_BITS
let PAGE_FREE: UWord = 0
let PAGE_RESERVED: UWord = 1
let PAGE_KERNEL: UWord = 2
let PAGE_DIRECTORY: UWord = 3
let PAGE_TABLE: UWord = 4
let PAGE_USER: UWord = 5
let PAGE_USER_STACK: UWord = 6
let PAGE_KERNEL_STACK: UWord = 7
// Address zero is permanently reserved: 0 is the explicit allocation failure.
let PAGE_NONE: UWord = 0
align(PAGE_SIZE) let mut pageBitmap: UWord[BITMAP_WORDS]
let mut pageOwners: *mut UWord
let mut pagePurposes: *mut UWord
// Managed user mappings and directory/table pins. The trusted supervisor
// physical window does not own frames. A referenced frame cannot be returned
// to the allocator, even through a task's creation-time ledger.
let mut pageReferences: *mut UWord
// MMU-only W/X accounting across all user aliases. High bit: executable;
// low 31 bits: number of aliases with that access. RO aliases do not count.
let mut pageAccessReferences: *mut UWord
let mut kernelReservedEnd: UWord
let mut kernelRamEnd: UWord
let mut nextFreePage: UWord

// Single CPU, before preemption: save/restore IE, never unconditionally enable
// interrupts. Nested calls also work in EXL=1. Fences order metadata and page
// clearing before restoring IE. This is not an SMP lock.
let memoryLock(): UWord {
    let status: UWord = mfcr(CR_STATUS)
    mtcr(CR_STATUS, status & ~STATUS_IE)
    fence()
    return status
}

let memoryUnlock(status: UWord): Void {
    fence()
    mtcr(CR_STATUS, status)
}

let memoryInit(ramSize: UWord): Bool {
    let status: UWord = memoryLock()
    // Reinitializing would forget live ownership; initialization is one-shot.
    if kernelRamEnd != 0 || ramSize == 0 || ramSize > RAM_MAX_BYTES {
        memoryUnlock(status)
        return false
    }
    let usedEnd: UWord = &__bss_end as UWord
    if usedEnd > ramSize {
        memoryUnlock(status)
        return false
    }
    let ramEnd: UWord = ramSize & ~PAGE_MASK
    let metadataStart: UWord = (usedEnd + PAGE_MASK) & ~PAGE_MASK
    let recordsBytes: UWord = (ramEnd / PAGE_SIZE) * WORD_BYTES
    // RAM_MAX_BYTES bounds both additions, including page rounding. Check the
    // complete metadata reservation before writing pointers or RAM contents.
    let reservedEnd: UWord = (metadataStart + 4 * recordsBytes + PAGE_MASK) & ~PAGE_MASK
    if metadataStart < PAGE_SIZE || reservedEnd > ramEnd {
        memoryUnlock(status)
        return false
    }
    pageOwners = metadataStart as *mut UWord
    pagePurposes = (metadataStart + recordsBytes) as *mut UWord
    pageReferences = (metadataStart + 2 * recordsBytes) as *mut UWord
    pageAccessReferences = (metadataStart + 3 * recordsBytes) as *mut UWord
    // Mark everything unavailable first, including the incomplete RAM tail.
    for i: UWord in 0..BITMAP_WORDS pageBitmap[i] = 0xFFFFFFFF
    for page: UWord in 0..(ramEnd / PAGE_SIZE) {
        pageOwners[page] = 0
        pagePurposes[page] = PAGE_RESERVED
        pageReferences[page] = 0
        pageAccessReferences[page] = 0
        if page >= reservedEnd / PAGE_SIZE {
            pageBitmap[page / WORD_BITS] &= ~(1 as UWord << (page % WORD_BITS))
            pagePurposes[page] = PAGE_FREE
        }
    }
    kernelReservedEnd = reservedEnd
    nextFreePage = reservedEnd / PAGE_SIZE
    // Publish readiness only after boot/image/BSS/stack/guard and the entire
    // installed-RAM metadata reservation have been accounted for.
    kernelRamEnd = ramEnd
    memoryUnlock(status)
    return true
}

let physicalPageUsable(address: UWord): Bool {
    return kernelRamEnd != 0 && address & PAGE_MASK == 0 &&
        address >= kernelReservedEnd && address < kernelRamEnd
}

// Range eligibility and availability are separate: this tests actual free
// state now. Queries are snapshots; only allocPage reserves a frame.
let physicalPageAvailable(address: UWord): Bool {
    let status: UWord = memoryLock()
    let mut available: Bool = false
    if physicalPageUsable(address) {
        let page: UWord = address / PAGE_SIZE
        available = pageBitmap[page / WORD_BITS] & (1 as UWord << (page % WORD_BITS)) == 0
    }
    memoryUnlock(status)
    return available
}

let pagePurposeValid(purpose: UWord): Bool {
    return purpose >= PAGE_KERNEL && purpose <= PAGE_KERNEL_STACK
}

// Internal query requires memoryLock; reserved/free frames have no owner.
let pageOwned(address: UWord, owner: UWord, purpose: UWord): Bool {
    if !physicalPageUsable(address) || owner == 0 || !pagePurposeValid(purpose) return false
    let page: UWord = address / PAGE_SIZE
    return pageBitmap[page / WORD_BITS] & (1 as UWord << (page % WORD_BITS)) != 0 &&
        pageOwners[page] == owner && pagePurposes[page] == purpose
}

let physicalPageOwned(address: UWord, owner: UWord, purpose: UWord): Bool {
    let status: UWord = memoryLock()
    let owned: Bool = pageOwned(address, owner, purpose)
    memoryUnlock(status)
    return owned
}

let retainPage(address: UWord, owner: UWord, purpose: UWord): Bool {
    let status: UWord = memoryLock()
    if !pageOwned(address, owner, purpose) || pageReferences[address / PAGE_SIZE] == 0xFFFFFFFF {
        memoryUnlock(status)
        return false
    }
    pageReferences[address / PAGE_SIZE] += 1
    memoryUnlock(status)
    return true
}

let releasePage(address: UWord, owner: UWord, purpose: UWord): Bool {
    let status: UWord = memoryLock()
    if !pageOwned(address, owner, purpose) || pageReferences[address / PAGE_SIZE] == 0 {
        memoryUnlock(status)
        return false
    }
    pageReferences[address / PAGE_SIZE] -= 1
    memoryUnlock(status)
    return true
}

let physicalPageReferences(address: UWord): UWord {
    let status: UWord = memoryLock()
    let mut count: UWord = 0
    if physicalPageUsable(address) count = pageReferences[address / PAGE_SIZE]
    memoryUnlock(status)
    return count
}

// Nonzero owner IDs are assigned by trusted kernel callers. For PAGE_USER and
// PAGE_USER_STACK, clear the entire frame before returning it to a new task.
let allocPage(owner: UWord, purpose: UWord): UWord {
    let status: UWord = memoryLock()
    if kernelRamEnd == 0 || owner == 0 || !pagePurposeValid(purpose) {
        memoryUnlock(status)
        return PAGE_NONE
    }
    for page: UWord in nextFreePage..(kernelRamEnd / PAGE_SIZE) {
        let bit: UWord = 1 as UWord << (page % WORD_BITS)
        if pageBitmap[page / WORD_BITS] & bit != 0 continue
        pageBitmap[page / WORD_BITS] |= bit
        pageOwners[page] = owner
        pagePurposes[page] = purpose
        nextFreePage = page + 1
        let address: UWord = page * PAGE_SIZE
        if purpose == PAGE_USER || purpose == PAGE_USER_STACK {
            let data: *mut UWord = address as *mut UWord
            for i: UWord in 0..(PAGE_SIZE / WORD_BYTES) data[i] = 0
        }
        memoryUnlock(status)
        return address
    }
    memoryUnlock(status)
    return PAGE_NONE
}

// Caller must first remove user mappings and deactivate any directory/stack
// using the frame. Reserved, foreign, misaligned, referenced and free pages
// are rejected. The supervisor physical window remains available for reuse.
let freePage(address: UWord, owner: UWord, purpose: UWord): Bool {
    let status: UWord = memoryLock()
    if !pageOwned(address, owner, purpose) || pageReferences[address / PAGE_SIZE] != 0 ||
        pageAccessReferences[address / PAGE_SIZE] != 0 {
        memoryUnlock(status)
        return false
    }
    let page: UWord = address / PAGE_SIZE
    pageOwners[page] = 0
    pagePurposes[page] = PAGE_FREE
    pageBitmap[page / WORD_BITS] &= ~(1 as UWord << (page % WORD_BITS))
    if page < nextFreePage nextFreePage = page
    memoryUnlock(status)
    return true
}

// Creation-time batch: caller supplies count empty output slots and immutable
// purposes in separate trusted kernel buffers, both outside allocatable RAM.
// On failure all pages allocated by THIS batch are returned and slots reset;
// existing allocations (even for the same owner) remain intact. Later loader
// or mapping failure uses freeTaskPages after removing mappings.
let allocTaskPages(owner: UWord, purposes: *UWord, pages: *mut UWord, count: UWord): Bool {
    let status: UWord = memoryLock()
    if kernelRamEnd == 0 || owner == 0 || purposes == null || pages == null ||
        count == 0 || count > MAX_PAGES {
        memoryUnlock(status)
        return false
    }
    for i: UWord in 0..count {
        if pages[i] != PAGE_NONE || !pagePurposeValid(purposes[i]) {
            memoryUnlock(status)
            return false
        }
    }
    for i: UWord in 0..count {
        let address: UWord = allocPage(owner, purposes[i])
        if address == PAGE_NONE {
            for allocated: UWord in 0..i {
                if !freePage(pages[allocated], owner, purposes[allocated]) {
                    memoryUnlock(status)
                    return false
                }
                pages[allocated] = PAGE_NONE
            }
            memoryUnlock(status)
            return false
        }
        pages[i] = address
    }
    memoryUnlock(status)
    return true
}

// Release an inactive creation-time batch, including after a later loader or
// mapping failure. Validate the entire ledger before changing any accounting.
// Small task batches are expected; the duplicate check is quadratic in count.
// Buffers obey the same trusted, separate, non-allocatable contract as above.
let freeTaskPages(owner: UWord, purposes: *UWord, pages: *mut UWord, count: UWord): Bool {
    let status: UWord = memoryLock()
    if owner == 0 || purposes == null || pages == null || count == 0 || count > MAX_PAGES {
        memoryUnlock(status)
        return false
    }
    for i: UWord in 0..count {
        if !pageOwned(pages[i], owner, purposes[i]) || pageReferences[pages[i] / PAGE_SIZE] != 0 ||
            pageAccessReferences[pages[i] / PAGE_SIZE] != 0 {
            memoryUnlock(status)
            return false
        }
        for previous: UWord in 0..i {
            if pages[previous] == pages[i] {
                memoryUnlock(status)
                return false
            }
        }
    }
    for i: UWord in 0..count {
        if !freePage(pages[i], owner, purposes[i]) {
            memoryUnlock(status)
            return false
        }
        pages[i] = PAGE_NONE
    }
    memoryUnlock(status)
    return true
}

export { kernelReservedEnd, kernelRamEnd, PAGE_NONE, PAGE_KERNEL,
    PAGE_DIRECTORY, PAGE_TABLE, PAGE_USER, PAGE_USER_STACK, PAGE_KERNEL_STACK,
    memoryInit, physicalPageAvailable, physicalPageOwned,
    MAX_PAGES, memoryLock, memoryUnlock, retainPage, releasePage, physicalPageReferences,
    pageAccessReferences,
    allocPage, freePage, allocTaskPages, freeTaskPages }
