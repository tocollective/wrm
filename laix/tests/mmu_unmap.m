// Expected: CAUSE=9, BADADDR=PROBE_VA, EPC=mmuLoadInstruction, exit 254.
// Access immediately after unmap; no remap/switch can flush on its behalf.
import { kernelInit } from "../src/boot.m"
import { panic, setPanicStage } from "../src/panic.m"
import { PTE_RW, PTE_U } from "../src/defs.m"
import { mapPage, unmapPage, mmuSwitchAddressSpace } from "../src/mmu.m"
import { PROBE_VA, probeRequire, probeSpace, probePage } from "mmu_probe.m"
extern let triggerMmuLoad(address: UWord): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("mmu-unmap-test")
    let directory: *mut UWord = probeSpace(7)
    let physical: UWord = probePage(7, 0xA0)
    probeRequire(mapPage(directory, 7, PROBE_VA, physical, PTE_RW | PTE_U))
    probeRequire(mmuSwitchAddressSpace(directory, 7, 7))
    probeRequire(*(PROBE_VA as *volatile UWord) == 0xA0)
    probeRequire(unmapPage(directory, 7, PROBE_VA))
    triggerMmuLoad(PROBE_VA)
    panic("unmapped CPU access unexpectedly returned", null)
    return 1
}
