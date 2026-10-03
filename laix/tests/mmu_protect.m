// Expected: CAUSE=10, BADADDR=PROBE_VA, EPC=mmuStoreInstruction, exit 254.
// Prime writable TLB access before revoking W through the real MMU API.
import { kernelInit } from "../src/boot.m"
import { panic, setPanicStage } from "../src/panic.m"
import { PTE_RW, PTE_RO, PTE_U } from "../src/defs.m"
import { mapPage, setPagePermissions, mmuSwitchAddressSpace } from "../src/mmu.m"
import { PROBE_VA, probeRequire, probeSpace, probePage } from "mmu_probe.m"
extern let triggerMmuStore(address: UWord): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("mmu-protect-test")
    let directory: *mut UWord = probeSpace(7)
    let physical: UWord = probePage(7, 0xA0)
    probeRequire(mapPage(directory, 7, PROBE_VA, physical, PTE_RW | PTE_U))
    probeRequire(mmuSwitchAddressSpace(directory, 7, 7))
    let word: *volatile mut UWord = PROBE_VA as *volatile mut UWord
    word[0] = 0xA1
    probeRequire(*word == 0xA1)
    probeRequire(setPagePermissions(directory, 7, PROBE_VA, PTE_RO | PTE_U))
    triggerMmuStore(PROBE_VA)
    panic("read-only CPU store unexpectedly returned", null)
    return 1
}
