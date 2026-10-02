// 16 cached disk pages, each holding sixteen 32-byte glyphs: 8 KiB of VRAM.
// FIFO replacement keeps hits free of disk I/O and bitmap copies.
type DiskRegs {
    status: UWord,
    sectors: UWord,
    sector: UWord,
    count: UWord,
    address: UWord,
    command: UWord,
    error: UWord,
}
type BootInfo {
    magic: UWord,
    size: UWord,
    ramSize: UWord,
    disk: UWord,
    diskSectors: UWord,
    image: UWord,
    imageSize: UWord,
    clock: UWord,
    devices: UWord,
    deviceTable: UWord,
}
let CACHE_BASE: UWord = 640 * 480
let CACHE_BYTES: UWord = 8192
let CACHE_GLYPHS: UWord = 256    // also the failure sentinel
let mut disk: *volatile mut DiskRegs
let mut firstSector: UWord
let mut glyphCount: UWord
let mut pages: UWord[16]
let mut nextSlot: UWord
let mut sectorData: UWord[128]   // aligned RAM buffer for disk DMA

let glyphCacheInit(count: UWord): Bool {
    disk = null
    glyphCount = 0
    nextSlot = 0
    for i: UWord in 0..16 pages[i] = 0xFFFFFFFF
    let info: *BootInfo = 0x1000 as *BootInfo
    if info.magic != 0x4F464E49 || info.size < sizeof(BootInfo) return false
    if info.image != 0x10000 || info.imageSize == 0 || info.imageSize & 511 != 0 return false
    if info.disk != 0xFD005000 && info.disk != 0xFD006000 && info.disk != 0xFD008000 return false
    let drive: *volatile mut DiskRegs = info.disk as *volatile mut DiskRegs
    let start: UWord = info.imageSize / 512
    let mut needed: UWord = count / 16
    if count % 16 != 0 needed++
    if count == 0 || drive.status & 1 == 0 || start > drive.sectors return false
    if needed > drive.sectors - start return false
    // An empty cache adopts the current boot medium. Drag & Drop leaves
    // CHANGED set for its insertion; acknowledge it once, before caching.
    // Later changes remain latched and cacheGlyph must reject them.
    drive.status = 32
    if drive.status & 1 == 0 || drive.status & 32 != 0 return false
    disk = drive
    firstSector = start
    glyphCount = count
    return true
}

// Returns a VRAM glyph slot, or CACHE_GLYPHS on a disk error.
let cacheGlyph(glyph: UWord): UWord {
    if disk == null || glyph >= glyphCount return CACHE_GLYPHS
    // Do not reuse cached pages after ejecting or replacing the boot disk.
    if disk.status & 1 == 0 || disk.status & 32 != 0 return CACHE_GLYPHS
    let page: UWord = glyph / 16
    for i: UWord in 0..16 {
        if pages[i] == page return i * 16 + glyph % 16
    }
    while disk.status & 4 != 0 {}
    disk.sector = firstSector + page
    disk.count = 1
    disk.address = &sectorData[0] as UWord
    disk.command = 1
    while disk.status & 8 == 0 {}
    fence()
    let error: UWord = disk.error
    disk.status = 8
    if error != 0 || disk.status & 32 != 0 return CACHE_GLYPHS
    let slot: UWord = nextSlot
    let target: *volatile mut UWord = (0xFC000000 + CACHE_BASE + slot * 512) as *volatile mut UWord
    for i: UWord in 0..128 target[i] = sectorData[i]
    fence()
    pages[slot] = page
    nextSlot = (slot + 1) % 16
    return slot * 16 + glyph % 16
}

export { CACHE_BASE, CACHE_BYTES, CACHE_GLYPHS, glyphCacheInit, cacheGlyph }
