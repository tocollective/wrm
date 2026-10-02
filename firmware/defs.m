// Hardware used by the WRM ROM firmware. Register layouts follow
// docs/SPECIFICATION.md; the boot structures follow its boot protocol.

type PicRegs {
    pending: UWord,
    enable: UWord,
    active: UWord,
    claim: UWord,
}

type KbdRegs {
    status: UWord,
    data: UWord,
    control: UWord,
}

type TimerRegs {
    countLo: UWord,
    countHi: UWord,
    frequency: UWord,
    reload: UWord,
    value: UWord,
    control: UWord,
    status: UWord,
}

type PowerRegs {
    off: UWord,
    reset: UWord,
    status: UWord,
    resetCause: UWord,
}

type DiskRegs {
    status: UWord,
    sectors: UWord,
    sector: UWord,
    count: UWord,
    address: UWord,
    command: UWord,
    error: UWord,
}

type Disk = *volatile mut DiskRegs

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
    reserved: UWord[4],
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

type BeeperRegs {
    control: UWord,
    frequency: UWord,
    duration: UWord,
}

let pic: *volatile mut PicRegs = 0xFD00_0000 as *volatile mut PicRegs
let kbd: *volatile mut KbdRegs = 0xFD00_1000 as *volatile mut KbdRegs
let timer: *volatile mut TimerRegs = 0xFD00_3000 as *volatile mut TimerRegs
let power: *volatile mut PowerRegs = 0xFD00_4000 as *volatile mut PowerRegs
let disk0: Disk = 0xFD00_5000 as Disk
let video: *volatile mut VideoRegs = 0xFD00_7000 as *volatile mut VideoRegs
let floppy: Disk = 0xFD00_8000 as Disk
let beeper: *volatile mut BeeperRegs = 0xFD00_9000 as *volatile mut BeeperRegs

let KBD_READY: UWord = 1
let DISK_PRESENT: UWord = 1
let DISK_DONE: UWord = 1 << 3
let DISK_READ: UWord = 1
let SECTOR_SIZE: UWord = 512

let VIDEO_DONE: UWord = 1 << 1
let VIDEO_BUSY: UWord = 1
let VIDEO_ENABLE: UWord = 1
let VIDEO_640X480: UWord = 1
let VIDEO_8BPP: UWord = 2 << 4
let VIDEO_FILL: UWord = 1
let VIDEO_COPY: UWord = 2
let VIDEO_EXPAND: UWord = 3
let VIDEO_LOAD: UWord = 4
let VIDEO_MEMORY: UWord = 1 << 9
let VRAM_SIZE: UWord = 0x40_0000

let BEEPER_ON: UWord = 1
let POWER_OFF_REQUEST: UWord = 1
let IRQ_POWER: UWord = 11

let CR_STATUS: UWord = 0
let CR_EPC: UWord = 1
let CR_IVEC: UWord = 2
let CR_CAUSE: UWord = 4
let CR_BADADDR: UWord = 5
let CR_PTBR: UWord = 6
let STATUS_EXL: UWord = 1 << 4

type BootHeader {
    magic: UWord,
    sectors: UWord,
    entry: UWord,
    flags: UWord,
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

type DeviceEntry {
    address: UWord,
    id: UWord,
}

let BOOT_MAGIC: UWord = 0x424D_5257
let BOOT_INFO_MAGIC: UWord = 0x4F46_4E49
let BOOT_INFO: UWord = 0x0000_1000
let BOOT_INFO_END: UWord = 0x0000_2000
let BOOT_STACK_TOP: UWord = 0x0001_0000
let BOOT_LOAD: UWord = 0x0001_0000

export {
    PicRegs, KbdRegs, TimerRegs, PowerRegs, DiskRegs, Disk, VideoRegs, BeeperRegs,
    pic, kbd, timer, power, disk0, video, floppy, beeper,
    KBD_READY, DISK_PRESENT, DISK_DONE, DISK_READ, SECTOR_SIZE,
    VIDEO_BUSY, VIDEO_DONE, VIDEO_ENABLE, VIDEO_640X480, VIDEO_8BPP,
    VIDEO_FILL, VIDEO_COPY, VIDEO_EXPAND, VIDEO_LOAD, VIDEO_MEMORY, VRAM_SIZE,
    BEEPER_ON, POWER_OFF_REQUEST, IRQ_POWER,
    CR_STATUS, CR_EPC, CR_IVEC, CR_CAUSE, CR_BADADDR, CR_PTBR, STATUS_EXL,
    BootHeader, BootInfo, DeviceEntry, BOOT_MAGIC, BOOT_INFO_MAGIC,
    BOOT_INFO, BOOT_INFO_END, BOOT_STACK_TOP, BOOT_LOAD,
}
