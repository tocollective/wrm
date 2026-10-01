// [6] Interrupts: the keyboard and the UART raise IRQs, trap() in trap.m
// calls onKey and onUart.

import {
    pic, kbd, uart, IRQ_KBD, IRQ_UART, KBD_FLUSH, KBD_OVERFLOW, UART_FLUSH, HOST_ESCAPE,
    CR_STATUS, STATUS_IE, HID_A, HID_ESCAPE,
} from "../defs.m"
import { puts, putc, printHex, show } from "../lib.m"
import { irqCount, trapInstall, setIrqHandler } from "../trap.m"

// shared with the handlers: atomics keep the accesses as they are written
let mut keyCount: UWord
let mut quit: UWord

let demoInterrupts(): Void {
    puts("\n[6] interrupts: press keys in the window (Esc quits)\n")
    puts("    or type in the terminal (echoed through the UART, Esc quits)\n")
    trapInstall()
    setIrqHandler(IRQ_KBD, onKey)
    setIrqHandler(IRQ_UART, onUart)
    kbd.control = KBD_FLUSH
    uart.control = UART_FLUSH
    pic.enable = 1 << IRQ_KBD | 1 << IRQ_UART
    mtcr(CR_STATUS, STATUS_IE)
    show("STATUS", mfcr(CR_STATUS))

    while true {
        wfi()                       // sleep; the handler runs and IRETs back here
        if atomicLoad(&quit) != 0 break
    }

    mtcr(CR_STATUS, 0)              // no interrupts after this
    pic.enable = 0
    show("interrupts taken", atomicLoad(&irqCount))
    show("keys pressed", atomicLoad(&keyCount))
}

/// Pops one keyboard event and describes it; Esc asks the demo to quit.
let onKey(): Void {
    if kbd.status & KBD_OVERFLOW != 0 {     // reading STATUS also clears the bit
        puts("keyboard FIFO overflowed, events were lost\n")
    }
    let event: UWord = kbd.data     // the line drops once the FIFO is empty
    let usage: UWord = event & 0xFFFF
    puts("key 0x")
    printHex(usage, 4)
    if event >> 31 != 0 {           // released
        puts(" released\n")
        return
    }
    keyCount++
    puts(" pressed")
    if usage - HID_A < 26 {         // letters a-z are usage IDs 0x04-0x1D
        putc(' ')
        putc('a' + (usage - HID_A) as UByte)
    }
    if usage == HID_ESCAPE {
        quit = 1
        puts(" (Esc)")
    }
    putc('\n')
}

/// Echoes one received byte back; Esc asks the demo to quit, so it also
/// runs without a window (--headless).
let onUart(): Void {
    let c: UWord = uart.data        // the line drops once the RX FIFO is empty
    if c == HOST_ESCAPE quit = 1 else putc(c as UByte)
}

export { demoInterrupts }
