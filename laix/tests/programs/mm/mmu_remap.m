// Expected: "MMU remap runtime OK", exit 0. Prime real translations before
// each mutation. No intervening PTBR writes may hide a missing TLBI.
import { kernelInit } from "../../../src/kernel/boot.m"
import { setPanicStage } from "../../../src/kernel/panic.m"
import { debugPrint } from "../../../src/drivers/debug_uart.m"
import { PTE_RW, PTE_RO, PTE_U, POWER_BASE } from "../../../src/arch/wrm081632/defs.m"
import { freePage, PAGE_USER } from "../../../src/mm/memory.m"
import { mapPage, unmapPage, setPagePermissions, mmuSwitchAddressSpace,
    mmuActivateKernel, mmuDestroyAddressSpace } from "../../../src/mm/mmu.m"
import { PROBE_VA, PROBE_OLD_VA, probeRequire, probeSpace, probePage } from "mmu_probe.m"

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("mmu-remap-test")
    let owner: UWord = 7
    let directory: *mut UWord = probeSpace(owner)
    let first: UWord = probePage(owner, 0xA0)
    let second: UWord = probePage(owner, 0xB0)
    probeRequire(mapPage(directory, owner, PROBE_VA, first, PTE_RW | PTE_U))
    // Keep the table alive for the first remap; then test freeing/recreating it.
    probeRequire(mapPage(directory, owner, PROBE_OLD_VA, second, PTE_RW | PTE_U))
    probeRequire(mmuSwitchAddressSpace(directory, owner, 7))
    let word: *volatile mut UWord = PROBE_VA as *volatile mut UWord
    probeRequire(*word == 0xA0)
    *word = 0xA1
    probeRequire(unmapPage(directory, owner, PROBE_VA))
    probeRequire(mapPage(directory, owner, PROBE_VA, second, PTE_RW | PTE_U))
    probeRequire(*word == 0xB0)
    *word = 0xB1
    probeRequire(*(first as *volatile UWord) == 0xA1)
    probeRequire(*(second as *volatile UWord) == 0xB1)
    probeRequire(unmapPage(directory, owner, PROBE_OLD_VA))
    probeRequire(unmapPage(directory, owner, PROBE_VA))
    probeRequire(mapPage(directory, owner, PROBE_VA, first, PTE_RO | PTE_U))
    probeRequire(*word == 0xA1)
    probeRequire(setPagePermissions(directory, owner, PROBE_VA, PTE_RW | PTE_U))
    *word = 0xA2
    probeRequire(*(first as *volatile UWord) == 0xA2)
    probeRequire(mmuActivateKernel())
    probeRequire(mmuDestroyAddressSpace(directory, owner))
    probeRequire(freePage(second, owner, PAGE_USER))
    debugPrint("MMU remap runtime OK\n")
    let power: *volatile mut UWord = POWER_BASE as *volatile mut UWord
    power[0] = 0
    while true { hlt() }
}
