// Expected: CAUSE=9, BADADDR=PROBE_OLD_VA, EPC=mmuLoadInstruction, exit 254.
// Create both owners' mappings BEFORE priming the old task's TLB. Recycle
// ASID 7 via ASID 0: a same-ASID MTCR alone could mask a missing TLBI.ALL.
import { kernelInit } from "../src/boot.m"
import { panic, setPanicStage } from "../src/panic.m"
import { debugPrint } from "../src/debug_uart.m"
import { PTE_RW, PTE_U } from "../src/defs.m"
import { mapPage, mmuSwitchAddressSpace, mmuActivateKernel } from "../src/mmu.m"
import { PROBE_VA, PROBE_OLD_VA, probeRequire, probeSpace, probePage } from "mmu_probe.m"
extern let triggerMmuLoad(address: UWord): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("asid-reuse-test")
    let first: *mut UWord = probeSpace(7)
    let second: *mut UWord = probeSpace(8)
    let oldPage: UWord = probePage(7, 0xA0)
    let newPage: UWord = probePage(8, 0xB0)
    probeRequire(mapPage(first, 7, PROBE_VA, oldPage, PTE_RW | PTE_U))
    probeRequire(mapPage(first, 7, PROBE_OLD_VA, oldPage, PTE_RW | PTE_U))
    probeRequire(mapPage(second, 8, PROBE_VA, newPage, PTE_RW | PTE_U))
    probeRequire(mmuSwitchAddressSpace(first, 7, 7))
    probeRequire(*(PROBE_VA as *volatile UWord) == 0xA0)
    probeRequire(*(PROBE_OLD_VA as *volatile UWord) == 0xA0)
    probeRequire(mmuActivateKernel())
    probeRequire(mmuSwitchAddressSpace(second, 8, 7))
    probeRequire(*(PROBE_VA as *volatile UWord) == 0xB0)
    debugPrint("ASID replacement mapping OK\n")
    triggerMmuLoad(PROBE_OLD_VA)
    panic("previous owner's CPU mapping unexpectedly returned", null)
    return 1
}
