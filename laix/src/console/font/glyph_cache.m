import { BOOT_INFO, BOOT_INFO_MAGIC, BOOT_LOAD, SECTOR_SIZE, SECTOR_MASK,
    DISK0_BASE, DISK1_BASE, FLOPPY_BASE, DISK_PRESENT, DISK_CHANGED, DISK_BUSY,
    DISK_DONE, DISK_READ, SCREEN_WIDTH, SCREEN_HEIGHT,
    WORD_BYTES, WORD_MASK, GLYPH_BYTES } from "../../arch/wrm081632/defs.m"
import { videoWriteWords } from "../../drivers/videocard.m"
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
let CACHE_PAGES: UWord = 16
let GLYPHS_PER_SECTOR: UWord = SECTOR_SIZE / GLYPH_BYTES
let SECTOR_WORDS: UWord = SECTOR_SIZE / WORD_BYTES
let EMPTY_CACHE_PAGE: UWord = WORD_MASK
let CACHE_BASE: UWord = SCREEN_WIDTH * SCREEN_HEIGHT
let CACHE_BYTES: UWord = CACHE_PAGES * SECTOR_SIZE
let CACHE_GLYPHS: UWord = CACHE_PAGES * GLYPHS_PER_SECTOR    // also the failure sentinel
let mut disk: *volatile mut DiskRegs
let mut firstSector: UWord
let mut glyphCount: UWord
let mut pages: UWord[CACHE_PAGES]
let mut nextSlot: UWord
let mut sectorData: UWord[SECTOR_WORDS]   // aligned RAM buffer for disk DMA

let glyphCacheInit(count: UWord): Bool {
    disk = null
    glyphCount = 0
    nextSlot = 0
    for i: UWord in 0..CACHE_PAGES pages[i] = EMPTY_CACHE_PAGE
    let info: *BootInfo = BOOT_INFO as *BootInfo
    if info.magic != BOOT_INFO_MAGIC || info.size < sizeof(BootInfo) return false
    if info.image != BOOT_LOAD || info.imageSize == 0 || info.imageSize & SECTOR_MASK != 0 return false
    if info.disk != DISK0_BASE && info.disk != DISK1_BASE && info.disk != FLOPPY_BASE return false
    let drive: *volatile mut DiskRegs = info.disk as *volatile mut DiskRegs
    let start: UWord = info.imageSize / SECTOR_SIZE
    let mut needed: UWord = count / GLYPHS_PER_SECTOR
    if count % GLYPHS_PER_SECTOR != 0 needed++
    if count == 0 || drive.status & DISK_PRESENT == 0 || start > drive.sectors return false
    if needed > drive.sectors - start return false
    // An empty cache adopts the current boot medium. Drag & Drop leaves
    // CHANGED set for its insertion; acknowledge it once, before caching.
    // Later changes remain latched and cacheGlyph must reject them.
    drive.status = DISK_CHANGED
    if drive.status & DISK_PRESENT == 0 || drive.status & DISK_CHANGED != 0 return false
    disk = drive
    firstSector = start
    glyphCount = count
    return true
}

// Returns a VRAM glyph slot, or CACHE_GLYPHS on a disk error.
let cacheGlyph(glyph: UWord): UWord {
    if disk == null || glyph >= glyphCount return CACHE_GLYPHS
    // Do not reuse cached pages after ejecting or replacing the boot disk.
    if disk.status & DISK_PRESENT == 0 || disk.status & DISK_CHANGED != 0 return CACHE_GLYPHS
    let page: UWord = glyph / GLYPHS_PER_SECTOR
    for i: UWord in 0..CACHE_PAGES {
        if pages[i] == page return i * GLYPHS_PER_SECTOR + glyph % GLYPHS_PER_SECTOR
    }
    while disk.status & DISK_BUSY != 0 {}
    disk.sector = firstSector + page
    disk.count = 1
    disk.address = &sectorData[0] as UWord
    disk.command = DISK_READ
    while disk.status & DISK_DONE == 0 {}
    fence()
    let error: UWord = disk.error
    disk.status = DISK_DONE
    if error != 0 || disk.status & DISK_CHANGED != 0 return CACHE_GLYPHS
    let slot: UWord = nextSlot
    if !videoWriteWords(CACHE_BASE + slot * SECTOR_SIZE, &sectorData[0], SECTOR_WORDS) return CACHE_GLYPHS
    pages[slot] = page
    nextSlot = (slot + 1) % CACHE_PAGES
    return slot * GLYPHS_PER_SECTOR + glyph % GLYPHS_PER_SECTOR
}

export { CACHE_BASE, CACHE_BYTES, CACHE_GLYPHS, glyphCacheInit, cacheGlyph }
