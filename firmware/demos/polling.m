// [5] Polling: the PIC line is enabled, but IE = 0.

import { pic, kbd, IRQ_KBD, KBD_READY, KBD_FLUSH } from "../defs.m"
import { puts, show } from "../lib.m"

let demoPolling(): Void {
    puts("\n[5] polling: press any key in the WRM window\n")
    kbd.control = KBD_FLUSH
    pic.enable = 1 << IRQ_KBD       // the line drives the CPU IRQ input...
    while true {
        wfi()                       // ...but with IE = 0 WFI just wakes up and continues
        if kbd.status & KBD_READY != 0 break
    }
    show("PIC PENDING", pic.pending)
    show("PIC CLAIM", pic.claim)
    show("keyboard event", kbd.data)    // pops the event
    pic.enable = 0
}

export { demoPolling }
