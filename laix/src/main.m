// LA/IX start.asm clears BSS, installs trapEntry and provides a kernel stack.
// Interrupts and the MMU remain disabled during this first kernel stage.
import { kernelInit } from "boot.m"
import { panic, setPanicStage } from "panic.m"
import { consoleInit, print, prints } from "console.m"

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    if !consoleInit() {
        panic("console initialization failed", null)
        return 1
    }
    setPanicStage("running")
    print("LA/IX\n")
    prints("answer = $i or $f, $h is also $s\n", -42, 42.0, 0x42, "correct")
    hlt()
    return 0
}
