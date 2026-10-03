import { debugPrint } from "../drivers/debug_uart.m"
import { panic, setPanicStage } from "panic.m"
import { trapLayoutValid } from "../trap/trap_frame.m"
import { trapRegisterSelfTest, trapExpect, trapExpectationMet } from "../trap/trap.m"
import { memoryInit } from "../mm/memory.m"
import { PAGE_SIZE, PAGE_MASK, WORD_BYTES, BOOT_INFO, BOOT_INFO_MAGIC,
    BOOT_INFO_BYTES, BOOT_INFO_LIMIT, DEVICE_ENTRY_BYTES, CAUSE_BREAKPOINT, CAUSE_SYSCALL,
    SYSCALL_UNSUPPORTED, ERRNO_ENOSYS, CR_STATUS, STATUS_IE, PIC_ENABLE } from "../arch/wrm081632/defs.m"
import { mmuInit } from "../mm/mmu.m"

type KernelBootInfo {
    magic: UWord,
    size: UWord,
    ramSize: UWord,
    disk: UWord,
    diskSectors: UWord,
    image: UWord,
    imageSize: UWord,
    clock: UWord,
    devices: UWord,
    deviceTable: UWord,
}

extern let bootInfoAddress: UWord
extern let __image_start: UByte
extern let __image_end: UByte
extern let __bss_end: UByte
extern let kernelStackGuard: UByte
extern let kernelStackBottom: UWord
extern let kernelStackTop: UByte
let mut kernelBootInfo: KernelBootInfo

let kernelIrqsDisabled(): Bool {
    let enable: *volatile UWord = PIC_ENABLE as *volatile UWord
    return mfcr(CR_STATUS) & STATUS_IE == 0 && *enable == 0
}

let kernelInit(): Void {
    setPanicStage("boot-info")
    if !kernelIrqsDisabled() {
        panic("IRQs enabled before IRQ handling is ready", null)
        return
    }
    debugPrint("LA/IX: kernel entry\n")
    let info: *KernelBootInfo = bootInfoAddress as *KernelBootInfo
    if bootInfoAddress != BOOT_INFO || info.magic != BOOT_INFO_MAGIC ||
        info.size < sizeof(KernelBootInfo) || info.size > BOOT_INFO_BYTES {
        panic("invalid boot info", null)
        return
    }
    let imageStart: UWord = &__image_start as UWord
    let imageEnd: UWord = &__image_end as UWord
    let stackBottom: UWord = &kernelStackBottom as UWord
    let stackTop: UWord = &kernelStackTop as UWord
    let stackGuard: UWord = &kernelStackGuard as UWord
    if info.image != imageStart || info.imageSize != imageEnd - imageStart ||
        info.ramSize < (&__bss_end as UWord) || info.clock == 0 ||
        stackGuard < imageEnd || stackGuard & PAGE_MASK != 0 ||
        stackBottom != stackGuard + PAGE_SIZE || stackBottom & PAGE_MASK != 0 ||
        stackTop <= stackBottom || stackTop & PAGE_MASK != 0 ||
        stackTop > (&__bss_end as UWord) {
        panic("invalid kernel memory layout", null)
        return
    }
    // start.asm has already written the entry state after BOOT_INFO_LIMIT:
    // a table reaching it would be overwritten.
    if info.devices > (BOOT_INFO_BYTES - sizeof(KernelBootInfo)) / DEVICE_ENTRY_BYTES || info.deviceTable < BOOT_INFO + info.size ||
        info.deviceTable > BOOT_INFO_LIMIT || info.deviceTable & (WORD_BYTES - 1) != 0 ||
        info.devices > (BOOT_INFO_LIMIT - info.deviceTable) / DEVICE_ENTRY_BYTES {
        panic("invalid device table", null)
        return
    }
    kernelBootInfo = *info
    setPanicStage("memory-init")
    if !memoryInit(info.ramSize) {
        panic("invalid physical page layout", null)
        return
    }
    setPanicStage("mmu-init")
    if !mmuInit() {
        panic("could not enable kernel memory protection", null)
        return
    }
    debugPrint("LA/IX: MMU enabled, kernel stack guard active, kernel W^X\n")
    if !trapLayoutValid() {
        panic("TrapFrame layout mismatch", null)
        return
    }
    setPanicStage("trap-selftest")
    trapExpect(CAUSE_BREAKPOINT)
    breakpoint()
    if !trapExpectationMet() {
        panic("breakpoint did not return through trapDispatch", null)
        return
    }
    // Arms its own BREAK and SYSCALL before raising each of them.
    let failed: Word = trapRegisterSelfTest()
    if failed != 0 || !trapExpectationMet() {
        panic("trap context was not preserved (failure=$h)", null, failed)
        return
    }
    trapExpect(CAUSE_SYSCALL)
    if syscall(SYSCALL_UNSUPPORTED, 1, 2, 3, 4, 5, 6) != -ERRNO_ENOSYS ||
        !trapExpectationMet() {
        panic("unknown syscall did not return -ENOSYS", null)
        return
    }
    if !kernelIrqsDisabled() {
        panic("trap return enabled IRQs", null)
        return
    }
    debugPrint("LA/IX: TrapFrame and syscall self-tests passed\n")
    setPanicStage("console-init")
}

export { KernelBootInfo, kernelBootInfo, kernelInit }
