// Custom LA/IX runtime required; m/tests/run.py uses the standard runtime.
// Expected UART: kernel entry, self-tests passed, trap runtime OK; exit 0.
import { kernelInit } from "../src/boot.m"
import { debugPrint } from "../src/debug_uart.m"
let TEST_POWER: *volatile mut UWord = 0xFD004000 as *volatile mut UWord

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    debugPrint("trap runtime OK\n")
    *TEST_POWER = 0
    while true { hlt() }
}
