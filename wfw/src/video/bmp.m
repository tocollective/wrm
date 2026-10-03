// Uncompressed, two-colour Windows BMPs (1 bpp) in ROM or RAM.
// Pixels are expanded by the video card into its current 8 bpp mode.

import {
    video, VIDEO_BUSY, VIDEO_DONE, VIDEO_EXPAND, VIDEO_MEMORY,
} from "../arch/wrm081632/defs.m"

type BmpInfo {
    width: UWord,
    height: UWord,
    stride: UWord,
    pixels: UWord,
    color0: UWord,
    color1: UWord,
    topDown: Bool,
}

// A 1 bpp line in the widest WRM video mode (1024 pixels). Copying into
// this aligned buffer also keeps the DMA's final word inside valid memory
// when a BMP's pixel array ends on an unaligned address.
type BmpLine = UByte[128]
align(4) let mut bmpLine: BmpLine

let bmpHalf(data: *UByte, offset: UWord): UWord {
    return data[offset] as UWord | (data[offset + 1] as UWord) << 8
}

let bmpWord(data: *UByte, offset: UWord): UWord {
    return data[offset] as UWord
        | (data[offset + 1] as UWord) << 8
        | (data[offset + 2] as UWord) << 16
        | (data[offset + 3] as UWord) << 24
}

/// Reads a BMP header. The caller supplies the actual byte length, so
/// malformed offsets and truncated pixel arrays can be rejected safely.
let bmpInfo(data: *UByte, length: UWord, out: *mut BmpInfo): Bool {
    if data == null || out == null || length < 62 return false
    if bmpHalf(data, 0) != 0x4D42 return false // "BM"

    let fileSize: UWord = bmpWord(data, 2)
    let dibSize: UWord = bmpWord(data, 14)
    if dibSize < 40 || dibSize > length - 14 return false
    let palette: UWord = 14 + dibSize
    if palette > length - 8 return false

    let pixels: UWord = bmpWord(data, 10)
    if pixels < palette + 8 || pixels > length return false
    if fileSize < pixels || fileSize > length return false
    if bmpHalf(data, 26) != 1 || bmpHalf(data, 28) != 1 return false
    if bmpWord(data, 30) != 0 return false // BI_RGB, no compression
    let used: UWord = bmpWord(data, 46)
    if used != 0 && used != 2 return false

    let width: UWord = bmpWord(data, 18)
    let rawHeight: UWord = bmpWord(data, 22)
    if width == 0 || width > 65535 || rawHeight == 0 || rawHeight == 0x8000_0000 return false
    let topDown: Bool = rawHeight & 0x8000_0000 != 0
    let mut height: UWord = rawHeight
    if topDown height = 0 - rawHeight
    if height > 65535 return false

    let stride: UWord = ((width + 31) / 32) * 4
    if height > (fileSize - pixels) / stride return false

    out.width = width
    out.height = height
    out.stride = stride
    out.pixels = pixels
    out.color0 = bmpWord(data, palette) & 0xFFFFFF
    out.color1 = bmpWord(data, palette + 4) & 0xFFFFFF
    out.topDown = topDown
    return true
}

/// Draws at (x, y). Palette entries zeroIndex and oneIndex take the BMP's
/// two RGB colours; the caller should choose entries it may temporarily own.
/// Returns false for an invalid BMP, unsupported video mode or DMA error.
let bmpDraw(data: *UByte, length: UWord, x: UWord, y: UWord,
            zeroIndex: UWord, oneIndex: UWord): Bool {
    let mut info: BmpInfo = {}
    if !bmpInfo(data, length, &mut info) return false
    if zeroIndex >= 256 || oneIndex >= 256 || zeroIndex == oneIndex return false
    if video.bpp != 8 return false
    let screenWidth: UWord = video.width
    let screenHeight: UWord = video.height
    if info.width > screenWidth || x > screenWidth - info.width return false
    if info.height > screenHeight || y > screenHeight - info.height return false
    if info.stride > sizeof(BmpLine) return false

    while video.status & VIDEO_BUSY != 0 {}
    video.paletteIndex = zeroIndex
    video.paletteData = info.color0
    video.paletteIndex = oneIndex
    video.paletteData = info.color1
    for row: UWord in 0..info.height {
        let mut sourceRow: UWord = row
        if !info.topDown sourceRow = info.height - 1 - row
        let source: UWord = info.pixels + sourceRow * info.stride
        for i: UWord in 0..info.stride bmpLine[i] = data[source + i]
        fence() // finish RAM writes before the video DMA reads this line
        video.srcBase = &bmpLine as UWord
        video.srcPitch = info.stride
        video.srcXY = 0
        video.dstBase = video.start
        video.dstPitch = video.pitch
        video.dstXY = x | ((y + row) << 16)
        video.size = info.width | (1 << 16)
        video.fg = oneIndex
        video.bg = zeroIndex
        video.command = VIDEO_EXPAND | VIDEO_MEMORY
        while video.status & VIDEO_DONE == 0 {}
        if video.error != 0 return false
    }
    return true
}

export { BmpInfo, bmpInfo, bmpDraw }
