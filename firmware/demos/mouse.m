// [10] Mouse: a pointer on the screen console and a little painting.
//
// The pointer is drawn by software, as on any machine with a relative
// mouse: before it is drawn, the pixels it covers are copied off screen
// (a COPY to VRAM past the frame), and copied back to erase it. The arrow
// is an EXPAND straight from its bitmap in ROM.

import {
    pic, kbd, uart, video, IRQ_KBD, IRQ_UART, IRQ_MOUSE, KBD_READY, KBD_FLUSH, UART_RX_READY,
    HOST_ESCAPE, HID_ESCAPE, MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE,
    VIDEO_BUSY, VIDEO_FILL, VIDEO_COPY, VIDEO_EXPAND, VIDEO_TRANSPARENT, VIDEO_MEMORY,
} from "../defs.m"
import { puts, show } from "../lib.m"
import { conClear, conPuts } from "../video.m"
import { MouseEvent, mouseEnable, mouseDisable, mouseRead } from "../mouse.m"

let SCREEN_W: Word = 640            // the console's mode: 640x480, 8 bpp
let SCREEN_H: Word = 480
let SCREEN_PITCH: UWord = 640
let SAVE_VRAM: UWord = 0x10_0000    // off screen: the pixels under the pointer
let ARROW_W: Word = 8
let ARROW_H: Word = 12
let ARROW_COLOR: UWord = 15         // white
let BRUSH: Word = 4                 // pixels a side
let FIRST_COLOR: UWord = 16         // the 6x6x6 colour cube of the palette
let COLORS: Word = 216

let ARROW: UByte[12] = [
    0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, 0xFF, 0xF8, 0xD8, 0x8C, 0x0C,
]

let HELP: *UByte = "[10] mouse: click to give the machine the mouse, Ctrl+Alt takes it back.\nLeft button paints, the wheel changes the colour, right button clears.\nThe middle button or Esc ends.\n"

let mut pointerX: Word
let mut pointerY: Word
let mut color: UWord

let demoMouse(): Void {
    puts("\n[10] mouse: click in the WRM window to give it the mouse (Ctrl+Alt takes it\n")
    puts("     back); left button paints, the wheel picks the colour, right button\n")
    puts("     clears, the middle button or Esc (window or terminal) ends\n")
    conClear()
    conPuts(HELP)
    pointerX = SCREEN_W / 2
    pointerY = SCREEN_H / 2
    color = 196                     // red, in the colour cube
    pointerSave()
    pointerDraw()

    mouseEnable()
    kbd.control = KBD_FLUSH
    pic.enable = 1 << IRQ_MOUSE | 1 << IRQ_KBD | 1 << IRQ_UART   // wake WFI, IE stays 0
    let mut events: UWord = 0
    let mut done: Bool = false
    let mut e: MouseEvent = {}
    while !done {
        wfi()
        while mouseRead(&mut e) {
            events++
            if handle(&e) done = true
        }
        if escapePressed() done = true
    }
    pic.enable = 0
    mouseDisable()

    show("mouse events", events)
    conClear()
    conPuts("[10] mouse: done\n")
}

/// Moves the pointer and paints, clears or changes the colour; true when
/// the demo should end.
let handle(e: *MouseEvent): Bool {
    pointerRestore()
    pointerX = clamp(pointerX + e.dx, 0, SCREEN_W - 1)
    pointerY = clamp(pointerY + e.dy, 0, SCREEN_H - 1)
    if e.wheel != 0 {
        let mut c: Word = ((color - FIRST_COLOR) as Word + e.wheel) % COLORS
        if c < 0 c += COLORS
        color = FIRST_COLOR + c as UWord
    }
    if e.buttons & MOUSE_RIGHT != 0 {
        conClear()
        conPuts(HELP)
    }
    if e.buttons & MOUSE_LEFT != 0 paint()
    pointerSave()
    pointerDraw()
    return e.buttons & MOUSE_MIDDLE != 0
}

/// Esc pressed in the window, or typed in the terminal.
let escapePressed(): Bool {
    let mut seen: Bool = false
    while kbd.status & KBD_READY != 0 {
        let key: UWord = kbd.data
        if key & 0xFFFF == HID_ESCAPE && key >> 31 == 0 seen = true
    }
    while uart.status & UART_RX_READY != 0 {
        if uart.data == HOST_ESCAPE seen = true
    }
    return seen
}

let clamp(v: Word, low: Word, high: Word): Word {
    if v < low return low
    if v > high return high
    return v
}

/// The part of a w x h rectangle at the pointer that is on the screen, as
/// SIZE.
let clipped(w: Word, h: Word): UWord {
    let cw: Word = clamp(SCREEN_W - pointerX, 0, w)
    let ch: Word = clamp(SCREEN_H - pointerY, 0, h)
    return cw as UWord | (ch as UWord) << 16
}

let pointerXY(): UWord {
    return pointerX as UWord | (pointerY as UWord) << 16
}

/// Waits for a DMA command of the engine (EXPAND from memory) to end:
/// until then it ignores new ones.
let videoIdle(): Void {
    while video.status & VIDEO_BUSY != 0 {}
}

/// Copies the pixels under the pointer off screen.
let pointerSave(): Void {
    videoIdle()
    video.srcBase = 0
    video.srcPitch = SCREEN_PITCH
    video.srcXY = pointerXY()
    video.dstBase = SAVE_VRAM
    video.dstPitch = ARROW_W as UWord
    video.dstXY = 0
    video.size = clipped(ARROW_W, ARROW_H)
    video.command = VIDEO_COPY
}

/// Puts them back, which erases the pointer.
let pointerRestore(): Void {
    videoIdle()
    video.srcBase = SAVE_VRAM
    video.srcPitch = ARROW_W as UWord
    video.srcXY = 0
    video.dstBase = 0
    video.dstPitch = SCREEN_PITCH
    video.dstXY = pointerXY()
    video.size = clipped(ARROW_W, ARROW_H)
    video.command = VIDEO_COPY
}

/// The arrow, its 1 bits only, from ROM.
let pointerDraw(): Void {
    videoIdle()
    video.srcBase = &ARROW as UWord
    video.srcPitch = 1
    video.srcXY = 0
    video.dstBase = 0
    video.dstPitch = SCREEN_PITCH
    video.dstXY = pointerXY()
    video.size = clipped(ARROW_W, ARROW_H)
    video.fg = ARROW_COLOR
    video.command = VIDEO_MEMORY | VIDEO_TRANSPARENT | VIDEO_EXPAND
}

/// A square of paint at the pointer.
let paint(): Void {
    videoIdle()
    video.dstBase = 0
    video.dstPitch = SCREEN_PITCH
    video.dstXY = pointerXY()
    video.size = clipped(BRUSH, BRUSH)
    video.fg = color
    video.command = VIDEO_FILL
}

export { demoMouse }
