// The machine for the firmware: device registers (docs/SPECIFICATION.md)
// as structs behind volatile pointers, their bits, control registers,
// the MMU and the boot protocol. Declarations only, no code.

// ---- devices ------------------------------------------------------------

type PicRegs {
    pending: UWord,
    enable:  UWord,
    active:  UWord,
    claim:   UWord,     // the lowest active line, 0xFFFFFFFF if none
}

type KbdRegs {
    status:  UWord,
    data:    UWord,     // pops an event: bit 31 = released, low 16 bits = usage ID
    control: UWord,
}

type UartRegs {
    data:    UWord,
    status:  UWord,
    control: UWord,
}

type TimerRegs {
    countLo:   UWord,
    countHi:   UWord,
    frequency: UWord,   // ticks per second
    reload:    UWord,
    value:     UWord,
    control:   UWord,
    status:    UWord,
}

type PowerRegs {
    off:   UWord,       // the low 8 bits are the exit code
    reset: UWord,
}

type DiskRegs {
    status:  UWord,
    sectors: UWord,
    sector:  UWord,
    count:   UWord,
    address: UWord,
    command: UWord,
    error:   UWord,
}

type VideoRegs {
    status:       UWord,    // 0x00
    control:      UWord,
    mode:         UWord,
    width:        UWord,
    height:       UWord,    // 0x10
    bpp:          UWord,
    pitch:        UWord,
    vramSize:     UWord,
    start:        UWord,    // 0x20
    frame:        UWord,
    paletteIndex: UWord,
    paletteData:  UWord,    // each write moves to the next entry
    reserved:     UWord[4], // 0x30
    command:      UWord,    // 0x40
    error:        UWord,
    dstBase:      UWord,
    dstPitch:     UWord,
    dstXY:        UWord,    // 0x50: x | y << 16
    srcBase:      UWord,
    srcPitch:     UWord,
    srcXY:        UWord,
    size:         UWord,    // 0x60: width | height << 16
    fg:           UWord,
    bg:           UWord,
    address:      UWord,
    count:        UWord,    // 0x70
}

type BeeperRegs {
    control:   UWord,
    frequency: UWord,       // Hz
    duration:  UWord,       // ticks, 0 = until turned off
}

type MouseRegs {
    status:  UWord,
    data:    UWord,     // pops an event, 0 if empty (mouse.m decodes it)
    control: UWord,
}

type NetRegs {
    status:     UWord,      // 0x00
    pending:    UWord,      // sockets (bits 0-7) and DNS (bit 8) raising the IRQ
    sockets:    UWord,
    reserved:   UWord,
    dnsCommand: UWord,      // 0x10
    dnsStatus:  UWord,
    dnsControl: UWord,
    dnsName:    UWord,      // address of a zero-terminated host name
    dnsResult:  UWord,      // 0x20: IPv4, 0 if the lookup failed
}

/// A socket of the network card: netSocket[n] is socket n.
type NetSocketRegs {
    state:     UWord,       // 0x00
    command:   UWord,
    error:     UWord,
    events:    UWord,       // writing 1 to a bit clears it
    irqMask:   UWord,       // 0x10
    localPort: UWord,
    peerAddr:  UWord,       // IPv4, 127.0.0.1 = 0x7F00_0001
    peerPort:  UWord,
    address:   UWord,       // 0x20: of the next byte to move
    count:     UWord,       // bytes left to move
    rxSize:    UWord,
    txFree:    UWord,
    reserved:  UWord[4],    // 0x30, the next socket at 0x40
}

type AudioRegs {
    status:  UWord,         // voices that signalled, writing 1 clears
    fault:   UWord,         // voices stopped by a bad address, writing 1 clears
    master:  UWord,         // left | right << 8, 0-255 each
    voices:  UWord,
    rate:    UWord,         // frames a second of the mix
}

/// A voice of the audio card: audioVoice[n] is voice n.
type AudioVoiceRegs {
    control:  UWord,        // 0x00
    address:  UWord,        // of the sample's first frame
    length:   UWord,        // in frames
    loop:     UWord,        // the frame a loop goes back to
    position: UWord,        // 0x10: the frame playing now
    rate:     UWord,        // frames a second
    volume:   UWord,        // left | right << 8, 0-255 each
    reserved: UWord,        // the next voice at 0x20
}

let pic: *volatile mut PicRegs = 0xFD00_0000 as *volatile mut PicRegs
let kbd: *volatile mut KbdRegs = 0xFD00_1000 as *volatile mut KbdRegs
let uart: *volatile mut UartRegs = 0xFD00_2000 as *volatile mut UartRegs
let timer: *volatile mut TimerRegs = 0xFD00_3000 as *volatile mut TimerRegs
let power: *volatile mut PowerRegs = 0xFD00_4000 as *volatile mut PowerRegs
let disk0: *volatile mut DiskRegs = 0xFD00_5000 as *volatile mut DiskRegs
let video: *volatile mut VideoRegs = 0xFD00_7000 as *volatile mut VideoRegs
let floppy: *volatile mut DiskRegs = 0xFD00_8000 as *volatile mut DiskRegs
let beeper: *volatile mut BeeperRegs = 0xFD00_9000 as *volatile mut BeeperRegs
let mouse: *volatile mut MouseRegs = 0xFD00_A000 as *volatile mut MouseRegs
let net: *volatile mut NetRegs = 0xFD00_B000 as *volatile mut NetRegs
let netSocket: *volatile mut NetSocketRegs = 0xFD00_B100 as *volatile mut NetSocketRegs
let audio: *volatile mut AudioRegs = 0xFD00_C000 as *volatile mut AudioRegs
let audioVoice: *volatile mut AudioVoiceRegs = 0xFD00_C100 as *volatile mut AudioVoiceRegs

let PIC_BASE: UWord = 0xFD00_0000      // the I/O region
let ROM_BASE: UWord = 0xFE00_0000

let IRQ_KBD: UWord = 0
let IRQ_UART: UWord = 1
let IRQ_TIMER: UWord = 2
let IRQ_MOUSE: UWord = 7
let IRQ_NET: UWord = 8
let IRQ_AUDIO: UWord = 9

let KBD_READY: UWord = 1 << 0
let KBD_OVERFLOW: UWord = 1 << 1
let KBD_FLUSH: UWord = 1 << 0

let UART_RX_READY: UWord = 1 << 0
let UART_TX_READY: UWord = 1 << 1
let UART_FLUSH: UWord = 1 << 0
let HOST_ESCAPE: UWord = 0x1B          // Esc typed in the host terminal

let TIMER_ENABLE: UWord = 1 << 0
let TIMER_PERIODIC: UWord = 1 << 1
let TIMER_EXPIRED: UWord = 1 << 0

let DISK_PRESENT: UWord = 1 << 0
let DISK_DONE: UWord = 1 << 3
let DISK_READ: UWord = 1
let SECTOR_SIZE: UWord = 512

let VIDEO_BUSY: UWord = 1 << 0
let VIDEO_DONE: UWord = 1 << 1
let VIDEO_ENABLE: UWord = 1 << 0
let VIDEO_320X240: UWord = 0           // MODE: resolution | depth
let VIDEO_640X480: UWord = 1
let VIDEO_800X600: UWord = 2
let VIDEO_1024X768: UWord = 3
let VIDEO_1BPP: UWord = 0 << 4
let VIDEO_4BPP: UWord = 1 << 4
let VIDEO_8BPP: UWord = 2 << 4
let VIDEO_16BPP: UWord = 3 << 4
let VIDEO_32BPP: UWord = 4 << 4
let VIDEO_FILL: UWord = 1              // commands
let VIDEO_COPY: UWord = 2
let VIDEO_EXPAND: UWord = 3
let VIDEO_LOAD: UWord = 4
let VIDEO_TRANSPARENT: UWord = 1 << 8  // EXPAND: 0 bits are left alone
let VIDEO_MEMORY: UWord = 1 << 9       // EXPAND: the bitmap is in RAM or ROM
let VRAM_SIZE: UWord = 0x40_0000

let BEEPER_ON: UWord = 1 << 0

let MOUSE_READY: UWord = 1 << 0        // STATUS
let MOUSE_OVERFLOW: UWord = 1 << 1
let MOUSE_FLUSH: UWord = 1 << 0        // CONTROL
let MOUSE_ENABLE: UWord = 1 << 1
let MOUSE_LEFT: UWord = 1 << 0         // buttons of an event
let MOUSE_RIGHT: UWord = 1 << 1
let MOUSE_MIDDLE: UWord = 1 << 2

let NET_LINK: UWord = 1 << 0           // STATUS
let NET_DNS_LOOKUP: UWord = 1          // DNS_COMMAND
let NET_DNS_BUSY: UWord = 1 << 0       // DNS_STATUS
let NET_DNS_DONE: UWord = 1 << 1
let NET_CLOSED: UWord = 0              // socket states
let NET_CONNECTING: UWord = 1
let NET_LISTENING: UWord = 2
let NET_CONNECTED: UWord = 3
let NET_PEER_CLOSED: UWord = 4
let NET_UDP_OPEN: UWord = 5
let NET_CONNECT: UWord = 1             // socket commands
let NET_LISTEN: UWord = 2
let NET_UDP: UWord = 3
let NET_SEND: UWord = 4
let NET_RECEIVE: UWord = 5
let NET_CLOSE: UWord = 6
let NET_EV_CONNECTED: UWord = 1 << 0   // socket events
let NET_EV_CLOSED: UWord = 1 << 1
let NET_EV_RECEIVED: UWord = 1 << 2
let NET_EV_SENT: UWord = 1 << 3
let NET_ERR_STATE: UWord = 2           // socket errors
let NET_ERR_NETWORK: UWord = 6

let VOICE_ON: UWord = 1 << 0           // voice CONTROL
let VOICE_LOOP: UWord = 1 << 1
let VOICE_16BIT: UWord = 1 << 2
let VOICE_STEREO: UWord = 1 << 3
let VOICE_SIGNAL_END: UWord = 1 << 4
let VOICE_SIGNAL_HALF: UWord = 1 << 5
let AUDIO_VOICES: UWord = 8

// ---- the CPU ---------------------------------------------------------------

// control registers (docs/INSTRUCTIONS.md#control-registers)
let CR_STATUS: UWord = 0
let CR_EPC: UWord = 1
let CR_IVEC: UWord = 2
let CR_CAUSE: UWord = 4
let CR_BADADDR: UWord = 5
let CR_PTBR: UWord = 6
let CR_CYCLE: UWord = 7
let CR_CYCLEH: UWord = 8
let CR_INSTRET: UWord = 9

let STATUS_IE: UWord = 1 << 0
let STATUS_PUM: UWord = 1 << 3         // user mode after IRET
let STATUS_EXL: UWord = 1 << 4         // in the handler: set on entry and at reset

let CAUSE_INTERRUPT: UWord = 0
let CAUSE_SYSCALL: UWord = 12

// MMU (docs/INSTRUCTIONS.md#memory-management)
let PTBR_EN: UWord = 1 << 0
let PTE_V: UWord = 1 << 0
let PTE_R: UWord = 1 << 1
let PTE_W: UWord = 1 << 2
let PTE_X: UWord = 1 << 3
let PTE_U: UWord = 1 << 4
let PAGE_SIZE: UWord = 0x1000
let SUPERPAGE_SIZE: UWord = 0x40_0000

// ---- the boot protocol (docs/SPECIFICATION.md#boot-protocol) ---------------

type BootHeader {
    magic:   UWord,
    sectors: UWord,         // image size in sectors, from sector 0
    entry:   UWord,         // offset from BOOT_LOAD
    flags:   UWord,         // must be 0
}

type BootInfo {
    magic:       UWord,
    size:        UWord,     // bytes of the block: later fields are new
    ramSize:     UWord,
    disk:        UWord,     // the boot disk's controller
    diskSectors: UWord,
    image:       UWord,     // = BOOT_LOAD
    imageSize:   UWord,
    clock:       UWord,     // ticks per second
}

let BOOT_MAGIC: UWord = 0x424D_5257    // "WRMB"
let BOOT_INFO_MAGIC: UWord = 0x4F46_4E49   // "INFO"
let BOOT_INFO: UWord = 0x0000_1000
let BOOT_STACK_TOP: UWord = 0x0001_0000
let BOOT_LOAD: UWord = 0x0001_0000

// USB HID usage IDs (page 0x07)
let HID_A: UWord = 0x04
let HID_ESCAPE: UWord = 0x29

export {
    PicRegs, KbdRegs, UartRegs, TimerRegs, PowerRegs, DiskRegs, VideoRegs, BeeperRegs,
    MouseRegs, NetRegs, NetSocketRegs, AudioRegs, AudioVoiceRegs,
    pic, kbd, uart, timer, power, disk0, video, floppy, beeper,
    mouse, net, netSocket, audio, audioVoice,
    PIC_BASE, ROM_BASE,
    IRQ_KBD, IRQ_UART, IRQ_TIMER, IRQ_MOUSE, IRQ_NET, IRQ_AUDIO,
    KBD_READY, KBD_OVERFLOW, KBD_FLUSH,
    UART_RX_READY, UART_TX_READY, UART_FLUSH, HOST_ESCAPE,
    TIMER_ENABLE, TIMER_PERIODIC, TIMER_EXPIRED,
    DISK_PRESENT, DISK_DONE, DISK_READ, SECTOR_SIZE,
    VIDEO_BUSY, VIDEO_DONE, VIDEO_ENABLE, VIDEO_320X240, VIDEO_640X480, VIDEO_800X600, VIDEO_1024X768,
    VIDEO_1BPP, VIDEO_4BPP, VIDEO_8BPP, VIDEO_16BPP, VIDEO_32BPP,
    VIDEO_FILL, VIDEO_COPY, VIDEO_EXPAND, VIDEO_LOAD, VIDEO_TRANSPARENT, VIDEO_MEMORY, VRAM_SIZE,
    BEEPER_ON,
    MOUSE_READY, MOUSE_OVERFLOW, MOUSE_FLUSH, MOUSE_ENABLE, MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE,
    NET_LINK, NET_DNS_LOOKUP, NET_DNS_BUSY, NET_DNS_DONE,
    NET_CLOSED, NET_CONNECTING, NET_LISTENING, NET_CONNECTED, NET_PEER_CLOSED, NET_UDP_OPEN,
    NET_CONNECT, NET_LISTEN, NET_UDP, NET_SEND, NET_RECEIVE, NET_CLOSE,
    NET_EV_CONNECTED, NET_EV_CLOSED, NET_EV_RECEIVED, NET_EV_SENT, NET_ERR_STATE, NET_ERR_NETWORK,
    VOICE_ON, VOICE_LOOP, VOICE_16BIT, VOICE_STEREO, VOICE_SIGNAL_END, VOICE_SIGNAL_HALF,
    AUDIO_VOICES,
    CR_STATUS, CR_EPC, CR_IVEC, CR_CAUSE, CR_BADADDR, CR_PTBR, CR_CYCLE, CR_CYCLEH, CR_INSTRET,
    STATUS_IE, STATUS_PUM, STATUS_EXL, CAUSE_INTERRUPT, CAUSE_SYSCALL,
    PTBR_EN, PTE_V, PTE_R, PTE_W, PTE_X, PTE_U, PAGE_SIZE, SUPERPAGE_SIZE,
    BootHeader, BootInfo, BOOT_MAGIC, BOOT_INFO_MAGIC, BOOT_INFO, BOOT_STACK_TOP, BOOT_LOAD,
    HID_A, HID_ESCAPE,
}
