import { VIDEO_BASE, VRAM_BASE, VIDEO_BUSY, VIDEO_ENABLE, VIDEO_FILL,
    VIDEO_COPY, VIDEO_EXPAND, WORD_BYTES } from "../arch/wrm081632/defs.m"

let VIDEO_RESERVED_WORDS: UWord = 4

// Video MMIO layout from docs/SPECIFICATION.md (Video card).
// Registers and the CPU's VRAM window stay private to this driver.
type VideoRegs {
    status: UWord,
    control: UWord,
    mode: UWord,
    width: UWord,
    height: UWord,
    bpp: UWord,
    pitch: UWord,
    vramSize: UWord,
    start: UWord,
    frame: UWord,
    paletteIndex: UWord,
    paletteData: UWord,
    reserved: UWord[VIDEO_RESERVED_WORDS],
    command: UWord,
    error: UWord,
    dstBase: UWord,
    dstPitch: UWord,
    dstXY: UWord,
    srcBase: UWord,
    srcPitch: UWord,
    srcXY: UWord,
    size: UWord,
    fg: UWord,
    bg: UWord,
    address: UWord,
    count: UWord,
}

let video: *volatile mut VideoRegs = VIDEO_BASE as *volatile mut VideoRegs

let videoWaitIdle(): Void {
    while video.status & VIDEO_BUSY != 0 {}
}

// Leave scanout disabled until the caller has checked the actual mode and
// prepared the framebuffer. This also drains DMA left by the firmware.
let videoSetMode(mode: UWord): Void {
    videoWaitIdle()
    video.control = 0
    video.mode = mode
    video.start = 0
}

let videoMode(): UWord { return video.mode }
let videoWidth(): UWord { return video.width }
let videoHeight(): UWord { return video.height }
let videoBpp(): UWord { return video.bpp }
let videoPitch(): UWord { return video.pitch }
let videoVramSize(): UWord { return video.vramSize }

let videoEnable(): Void {
    video.control = VIDEO_ENABLE
}

let videoSetPalette(index: UWord, color: UWord): Void {
    video.paletteIndex = index
    video.paletteData = color
}

// xy and size pack x/width into bits 0..15 and y/height into bits 16..31.
// Bases are VRAM byte offsets; pitches are bytes per row. FILL, COPY and
// EXPAND from VRAM complete within the command store: return ERROR directly.
// The card validates rectangles; a nonzero ERROR means nothing was drawn.
let videoFill(base: UWord, pitch: UWord, xy: UWord, size: UWord, color: UWord): UWord {
    videoWaitIdle()
    video.dstBase = base
    video.dstPitch = pitch
    video.dstXY = xy
    video.size = size
    video.fg = color
    video.command = VIDEO_FILL
    return video.error
}

// COPY supports overlapping source and destination rectangles.
let videoCopy(dstBase: UWord, dstPitch: UWord, dstXY: UWord,
    srcBase: UWord, srcPitch: UWord, srcXY: UWord, size: UWord): UWord {
    videoWaitIdle()
    video.dstBase = dstBase
    video.dstPitch = dstPitch
    video.dstXY = dstXY
    video.srcBase = srcBase
    video.srcPitch = srcPitch
    video.srcXY = srcXY
    video.size = size
    video.command = VIDEO_COPY
    return video.error
}

// Expand a 1bpp VRAM bitmap into foreground/background pixels.
let videoExpand(dstBase: UWord, dstPitch: UWord, dstXY: UWord,
    srcBase: UWord, srcPitch: UWord, srcXY: UWord, size: UWord,
    fg: UWord, bg: UWord): UWord {
    videoWaitIdle()
    video.dstBase = dstBase
    video.dstPitch = dstPitch
    video.dstXY = dstXY
    video.srcBase = srcBase
    video.srcPitch = srcPitch
    video.srcXY = srcXY
    video.size = size
    video.fg = fg
    video.bg = bg
    video.command = VIDEO_EXPAND
    return video.error
}

// Upload count aligned words through the CPU VRAM window, then make them
// visible to the drawing engine. The caller supplies count readable words.
// Validate without overflowing the offset or byte count; never partially copy.
let videoWriteWords(offset: UWord, source: *UWord, count: UWord): Bool {
    if count == 0 return true
    if source == null || (source as UWord) % WORD_BYTES != 0 || offset % WORD_BYTES != 0 return false
    let capacity: UWord = videoVramSize()
    if offset > capacity || count > (capacity - offset) / WORD_BYTES return false
    videoWaitIdle()
    let target: *volatile mut UWord = (VRAM_BASE + offset) as *volatile mut UWord
    for i: UWord in 0..count target[i] = source[i]
    fence()
    return true
}

// Scanout happens at the next frame. Wait before the caller can HLT.
let videoWaitFrame(): Void {
    let frame: UWord = video.frame
    while video.frame == frame {}
}

export { videoSetMode, videoMode, videoWidth, videoHeight, videoBpp, videoPitch,
    videoVramSize, videoEnable, videoSetPalette, videoFill, videoCopy, videoExpand,
    videoWriteWords, videoWaitFrame }
