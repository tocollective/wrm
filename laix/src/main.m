// LA/IX start.asm clears BSS, installs trapEntry and provides a kernel stack.
// Interrupts and the MMU remain disabled during this first kernel stage.
import { kernelInit } from "boot.m"
import { panic, setPanicStage } from "panic.m"
import { consoleInit, print, putChar } from "console.m"
import { rngWord } from "rnd.m"

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    if !consoleInit() {
        panic("console initialization failed", null)
        return 1
    }
    setPanicStage("running")
    print("LA/IX\n")
    hlt()
    return 0
}
