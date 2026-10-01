// [9] Video modes: every depth, in the four resolutions.

import {
    video, kbd, KBD_READY, KBD_FLUSH, VIDEO_FILL,
    VIDEO_320X240, VIDEO_640X480, VIDEO_800X600, VIDEO_1024X768,
    VIDEO_1BPP, VIDEO_4BPP, VIDEO_8BPP, VIDEO_16BPP, VIDEO_32BPP,
} from "../defs.m"
import { puts, putc } from "../lib.m"
import { videoInit, videoGlyph, videoText, conPuts } from "../video.m"

let SHOW_FRAMES: UWord = 120        // 2 seconds at 60 frames a second

type Mode {
    mode:  UWord,
    draw:  (): Void,                // the picture
    label: *UByte,
    color: UWord,                   // of the label
}

let MODES: Mode[5] = [
    { .mode = VIDEO_640X480 | VIDEO_8BPP, .draw = drawPalette8,
      .label = "640x480, 8 bpp: the 256-colour palette", .color = 15 },
    { .mode = VIDEO_320X240 | VIDEO_4BPP, .draw = drawBars4,
      .label = "320x240, 4 bpp: 16 colours", .color = 15 },
    { .mode = VIDEO_800X600 | VIDEO_16BPP, .draw = drawRamps16,
      .label = "800x600, 16 bpp: RGB565", .color = 0xFFFF },
    { .mode = VIDEO_1024X768 | VIDEO_32BPP, .draw = drawRamps32,
      .label = "1024x768, 32 bpp: XRGB8888", .color = 0xFFFFFF },
    { .mode = VIDEO_640X480 | VIDEO_1BPP, .draw = drawFont1,
      .label = "640x480, 1 bpp: the font", .color = 1 },
]

let demoVideo(): Void {
    puts("\n[9] video: a mode every 2 seconds, a key in the WRM window skips\n")
    kbd.control = KBD_FLUSH         // drop the releases of earlier demos
    for i: UWord in 0..5 {
        let m: *Mode = &MODES[i]
        puts(m.label)               // say which mode on the UART too
        putc('\n')
        videoScreen(m.mode)
        m.draw()
        videoText(m.label, 8 << 16 | 8, m.color, 0, 0)    // bg 0 is black in every depth
        videoWait(SHOW_FRAMES)
    }
    videoInit()                     // back to the console, with its palette
    conPuts("[9] video: done\n")
}

/// Sets the mode, makes the whole visible frame the destination surface
/// and clears it to 0.
let videoScreen(mode: UWord): Void {
    video.mode = mode
    video.dstBase = 0
    video.dstPitch = video.pitch
    video.dstXY = 0
    video.size = video.width | video.height << 16
    video.fg = 0
    video.command = VIDEO_FILL
}

/// Returns after that many frames, or earlier when a key is pressed in
/// the window.
let videoWait(frames: UWord): Void {
    let end: UWord = video.frame + frames
    while true {
        if kbd.status & KBD_READY != 0 && kbd.data >> 31 == 0 return   // pressed, not released
        if ((end - video.frame) as Word <= 0) return    // the difference survives FRAME wrapping
    }
}

/// Fills a rectangle of the destination surface.
let fill(x: UWord, y: UWord, color: UWord): Void {
    video.dstXY = x | y << 16
    video.fg = color
    video.command = VIDEO_FILL
}

/// 640x480, 8 bpp: the 256 palette entries in a 16x16 grid.
let drawPalette8(): Void {
    video.size = 30 << 16 | 40      // 640 / 16 by 480 / 16
    for entry: UWord in 0..256 fill((entry & 15) * 40, (entry >> 4) * 30, entry)
}

/// 320x240, 4 bpp: the 16 colours as vertical bars.
let drawBars4(): Void {
    video.size = 240 << 16 | 20
    for color: UWord in 0..16 fill(color * 20, 0, color)
}

/// 800x600, 16 bpp: red, green and blue ramps of RGB565, 32 steps each.
let drawRamps16(): Void {
    video.size = 200 << 16 | 25
    for step: UWord in 0..32 {
        fill(step * 25, 0, step << 11)          // red
        fill(step * 25, 200, step << 6)         // green: 6 bits, every other level
        fill(step * 25, 400, step)              // blue
    }
}

/// 1024x768, 32 bpp: red, green, blue and grey ramps, 256 steps each.
let drawRamps32(): Void {
    video.size = 192 << 16 | 4
    for step: UWord in 0..256 {
        fill(step * 4, 0, step << 16)
        fill(step * 4, 192, step << 8)
        fill(step * 4, 384, step)
        fill(step * 4, 576, step << 16 | step << 8 | step)
    }
}

/// 640x480, 1 bpp: the whole font on green phosphor.
let drawFont1(): Void {
    video.paletteIndex = 0
    video.paletteData = 0           // 0: black
    video.paletteData = 0x33FF66    // 1: green
    for c: UWord in 0..256 {        // 16x16 cells of 24 pixels from (128, 48)
        let x: UWord = (c & 15) * 24 + 128
        let y: UWord = (c >> 4) * 24 + 48
        videoGlyph(c as UByte, x | y << 16, 1, 0, 0)
    }
}

export { demoVideo }
