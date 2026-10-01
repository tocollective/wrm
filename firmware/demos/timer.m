// [8] Timer and cycle counters.

import {
    pic, timer, IRQ_TIMER, TIMER_ENABLE, TIMER_PERIODIC, TIMER_EXPIRED,
    CR_STATUS, CR_CYCLE, CR_INSTRET, STATUS_IE,
} from "../defs.m"
import { puts, show, Cycles, readCycles } from "../lib.m"
import { trapInstall, setIrqHandler } from "../trap.m"

let TIMER_HZ: UWord = 100       // periodic interrupt rate
let TIMER_TICKS: UWord = 10     // interrupts to wait for: 0.1s

let mut ticks: UWord

let demoTimer(): Void {
    puts("\n[8] timer and cycle counters\n")

    // CYCLE and INSTRET run freely; the difference of two reads measures
    // the code in between
    let cycles: UWord = mfcr(CR_CYCLE)
    let instret: UWord = mfcr(CR_INSTRET)
    for i: UWord in 0..100 {}
    show("100-pass loop, cycles", mfcr(CR_CYCLE) - cycles)
    show("  instructions", mfcr(CR_INSTRET) - instret)

    show("timer FREQUENCY, Hz", timer.frequency)   // = the clock rate: the timer counts ticks

    // periodic interrupt, TIMER_HZ times a second
    ticks = 0
    trapInstall()
    setIrqHandler(IRQ_TIMER, onTimer)
    timer.reload = timer.frequency / TIMER_HZ      // period in ticks
    timer.control = TIMER_ENABLE | TIMER_PERIODIC  // counts down from RELOAD
    pic.enable = 1 << IRQ_TIMER
    let start: Cycles = readCycles()
    mtcr(CR_STATUS, STATUS_IE)
    while true {
        wfi()                       // sleeps until the next tick
        if atomicLoad(&ticks) >= TIMER_TICKS break
    }
    mtcr(CR_STATUS, 0)
    let end: Cycles = readCycles()
    timer.control = 0               // stop
    timer.status = TIMER_EXPIRED    // drop a tick that came after IE = 0
    pic.enable = 0

    show("ticks at 100 Hz", ticks)
    show("cycles for them", end.lo - start.lo)     // elapsed, fits in the low half
}

/// Acknowledges the tick, which drops the line, and counts it.
let onTimer(): Void {
    timer.status = TIMER_EXPIRED
    ticks++
}

export { demoTimer }
