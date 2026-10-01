// Example boot image: sends every byte received on the UART back to it.
// Esc, typed or piped, powers the machine off.
//
// Build:  python3 tools/m.py firmware/disk/echo.m -o echo.s
//         python3 tools/asm.py echo.s --base 0x10000 -o echo.img
// Run:    bin/wrm081632 --headless --hdd echo.img
//         printf 'hello\n\033' | bin/wrm081632 --headless --hdd echo.img
//
// The UART line has no end of input: piped data has to end with Esc, or
// the image keeps waiting after it.

import { pic, uart, IRQ_UART, UART_RX_READY, HOST_ESCAPE } from "../defs.m"
import { puts, putc } from "../lib.m"

let main(argc: UWord, argv: *UByte[]): Word {
    puts("\nUART echo, Esc quits\n")
    pic.enable = 1 << IRQ_UART      // wakes WFI; IE stays 0, so no traps
    while true {
        while uart.status & UART_RX_READY == 0 wfi()
        let c: UWord = uart.data
        if c == HOST_ESCAPE break
        putc(c as UByte)
    }
    pic.enable = 0
    return 0
}
