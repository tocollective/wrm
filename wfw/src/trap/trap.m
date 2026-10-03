// Fatal firmware traps are reported on the screen and power the machine off.
// The assembly entry switches to a known stack. The handler never returns.

import { CR_IVEC, CR_CAUSE, CR_EPC, CR_BADADDR, power } from "../arch/wrm081632/defs.m"
import { write, writeHex } from "../console/console.m"

extern let firmwareTrapEntry(): Void

let installTrap(): Void {
    mtcr(CR_IVEC, firmwareTrapEntry as UWord)
}

let firmwarePanic(): Void {
    write("\nFirmware exception\nCAUSE   ")
    writeHex(mfcr(CR_CAUSE))
    write("\nEPC     ")
    writeHex(mfcr(CR_EPC))
    write("\nBADADDR ")
    writeHex(mfcr(CR_BADADDR))
    write("\n")
    power.off = 254
    while true {}
}

export { installTrap, firmwarePanic }
