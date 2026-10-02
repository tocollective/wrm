import { debugPrint, debugHex } from "debug_uart.m"
import { panic, setPanicStage } from "panic.m"
import { trapLayoutValid } from "trap_frame.m"
import { trapRegisterSelfTest, trapBreakCount } from "trap.m"

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
extern let kernelStackBottom: UWord
extern let kernelStackTop: UByte
let mut kernelBootInfo: KernelBootInfo

let kernelInit(): Void {
    setPanicStage("boot-info")
    debugPrint("LA/IX: kernel entry\n")
    let info: *KernelBootInfo = bootInfoAddress as *KernelBootInfo
    if bootInfoAddress != 0x1000 || info.magic != 0x4F464E49 ||
        info.size < sizeof(KernelBootInfo) || info.size > 0x1000 {
        panic("invalid boot info", null)
        return
    }
    let imageStart: UWord = &__image_start as UWord
    let imageEnd: UWord = &__image_end as UWord
    let stackBottom: UWord = &kernelStackBottom as UWord
    let stackTop: UWord = &kernelStackTop as UWord
    if info.image != imageStart || info.imageSize != imageEnd - imageStart ||
        info.ramSize < (&__bss_end as UWord) || info.clock == 0 ||
        stackBottom < imageEnd || stackTop <= stackBottom || stackTop & 7 != 0 {
        panic("invalid kernel memory layout", null)
        return
    }
    if info.devices > 507 || info.deviceTable < 0x1000 + info.size ||
        info.deviceTable > 0x2000 || info.deviceTable & 3 != 0 ||
        info.devices > (0x2000 - info.deviceTable) / 8 {
        panic("invalid device table", null)
        return
    }
    kernelBootInfo = *info
    if !trapLayoutValid() {
        panic("TrapFrame layout mismatch", null)
        return
    }
    setPanicStage("trap-selftest")
    let before: UWord = trapBreakCount()
    let failed: Word = trapRegisterSelfTest()
    if failed != 0 || trapBreakCount() != before + 1 {
        debugPrint("trap self-test failure=")
        debugHex(failed as UWord)
        panic("trap context was not preserved", null)
        return
    }
    if syscall(0xFFFFFFFF, 1, 2, 3, 4, 5, 6) != -38 {
        panic("unknown syscall did not return -ENOSYS", null)
        return
    }
    debugPrint("LA/IX: TrapFrame and syscall self-tests passed\n")
    setPanicStage("console-init")
}

export { KernelBootInfo, kernelBootInfo, kernelInit }
