// Mouse: enabling it and decoding its events.
//
// The mouse is relative: an event says how far it moved and which buttons
// are down after it. While it is enabled, a click in the emulator's window
// gives it the host pointer, and Ctrl+Alt takes the pointer back.

import { mouse, MOUSE_FLUSH, MOUSE_ENABLE } from "defs.m"

type MouseEvent {
    dx:      Word,          // to the right
    dy:      Word,          // down, as the screen's y
    wheel:   Word,          // steps away from the user
    buttons: UWord,         // MOUSE_LEFT | MOUSE_RIGHT | MOUSE_MIDDLE
}

/// Enables the mouse with an empty FIFO.
let mouseEnable(): Void {
    mouse.control = MOUSE_FLUSH | MOUSE_ENABLE
}

/// Disables it: the host gets its pointer back and nothing more is queued.
let mouseDisable(): Void {
    mouse.control = MOUSE_FLUSH
}

/// Pops the next event into e; false if there is none.
let mouseRead(e: *mut MouseEvent): Bool {
    let raw: UWord = mouse.data         // never 0 for an event
    if raw == 0 return false
    e.dx = (raw as Byte) as Word        // signed bytes
    e.dy = ((raw >> 8) as Byte) as Word
    e.wheel = ((raw >> 16) as Byte) as Word
    e.buttons = raw >> 24 & 7
    return true
}

export { MouseEvent, mouseEnable, mouseDisable, mouseRead }
