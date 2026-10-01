// [7] MMU and user mode.
//
// The supervisor keeps its view of the machine through 4MB superpages
// mapped one to one (RAM: RW, I/O: RW, ROM: RX), none of them with U.
// The user program (userPage in mmu.asm) gets its own two pages:
//   USER_CODE -> userPage in ROM   R X U
//   USER_DATA -> userData          R W U   (its stack)

import {
    PIC_BASE, ROM_BASE, CR_PTBR, CR_STATUS, CR_EPC, CR_BADADDR, CAUSE_SYSCALL,
    PTBR_EN, PTE_V, PTE_R, PTE_W, PTE_X, PTE_U, SUPERPAGE_SIZE,
} from "../defs.m"
import { puts, show } from "../lib.m"
import { TrapFrame, trapInstall, setFaultHandler } from "../trap.m"

let USER_CODE: UWord = 0x0040_0000
let USER_DATA: UWord = 0x0040_1000

// system calls: r9 = number, r1 = argument (docs/ABI.md#system-calls)
let SYS_EXIT: UWord = 0
let SYS_PUTS: UWord = 1     // r1 = zero-terminated string

align(4096) let mut pageDir: UWord[1024]
align(4096) let mut pageTable: UWord[1024]  // virtual 0x00400000-0x007FFFFF
align(4096) let mut userData: UWord[1024]
align(4096) let mut spare: UWord[1024]

/// r10-r27, fp, sp, ra of the supervisor while user code runs (mmu.asm).
let mut userContext: UWord[21]

extern let userPage: UByte
extern let enterUser(entry: UWord): Void
extern let leaveUser(): Void

let demoMmu(): Void {
    puts("\n[7] MMU and user mode\n")
    pageDir = []
    pageTable = []

    // supervisor superpages
    pageDir[0] = 0x0000_0000 | PTE_V | PTE_R | PTE_W                // RAM
    pageDir[PIC_BASE >> 22] = PIC_BASE | PTE_V | PTE_R | PTE_W      // devices
    for i: UWord in 0..8 {                                         // the 32MB ROM
        pageDir[(ROM_BASE >> 22) + i] = ROM_BASE + i * SUPERPAGE_SIZE | PTE_V | PTE_R | PTE_X
    }

    // the user pages go through a page table: no R, W or X in the
    // directory entry means "pointer to a table"
    pageDir[USER_CODE >> 22] = &pageTable as UWord | PTE_V
    pageTable[0] = &userPage as UWord | PTE_V | PTE_R | PTE_X | PTE_U
    pageTable[1] = &userData as UWord | PTE_V | PTE_R | PTE_W | PTE_U

    setFaultHandler(onTrap)
    trapInstall()
    mtcr(CR_PTBR, &pageDir as UWord | PTBR_EN)  // translation on from here
    show("PTBR", mfcr(CR_PTBR))

    // one virtual page, two physical ones: remapping needs TLBI
    let page: *volatile UWord = USER_DATA as *volatile UWord
    userData[0] = 0x1111
    spare[0] = 0x2222
    show("LW 0x00401000", *page)            // through userData, now in the TLB
    pageTable[1] = &spare as UWord | PTE_V | PTE_R | PTE_W | PTE_U
    tlbi(USER_DATA)                         // drop the stale translation
    show("remap + TLBI, LW again", *page)   // now through spare
    pageTable[1] = &userData as UWord | PTE_V | PTE_R | PTE_W | PTE_U
    tlbi(USER_DATA)

    enterUser(USER_CODE)                    // back on SYS_EXIT
    show("back in supervisor, STATUS", mfcr(CR_STATUS))
    mtcr(CR_PTBR, 0)                        // translation off again
    setFaultHandler(null)
}

/// Faults and system calls of the user program. Supervisor code may read
/// user pages, so strings are passed by address.
let onTrap(frame: *mut TrapFrame, cause: UWord): Void {
    if cause == CAUSE_SYSCALL {
        let number: UWord = frame.regs[8]   // the user's r9
        if number == SYS_EXIT leaveUser()   // doesn't return
        if number == SYS_PUTS puts(frame.regs[0] as *UByte)
    } else {
        show("  trap: CAUSE", cause)
        show("        EPC", mfcr(CR_EPC))
        show("        BADADDR", mfcr(CR_BADADDR))
    }
    mtcr(CR_EPC, mfcr(CR_EPC) + 4)          // continue after the instruction
}

export { demoMmu, userContext }
