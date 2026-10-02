// LA/IX start.asm clears BSS, installs trapEntry and provides a kernel stack.
// kernelInit enables the stack guard through MMU; interrupts stay disabled.
import { kernelInit } from "boot.m"
import { panic, setPanicStage } from "panic.m"
import { consoleInit, print } from "console.m"

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    if !consoleInit() {
        panic("console initialization failed", null)
        return 1
    }
    setPanicStage("running")
    print("LA/IX\n")

    // 

    hlt()
    return 0
}
