; ============================================================================
;  Hardware constants and a RAM layout for the test ROMs (the firmware,
;  now in M, has its own in firmware/defs.m). Constants only, no code or
;  data.
; ============================================================================

; ---- memory map (docs/SPECIFICATION.md) ------------------------------------

ROM_BASE        = 0xFE000000
PIC             = 0xFD000000
KBD             = 0xFD001000
UART            = 0xFD002000
TIMER           = 0xFD003000
POWER           = 0xFD004000
DISK0           = 0xFD005000
DISK1           = 0xFD006000
VIDEO           = 0xFD007000
FLOPPY          = 0xFD008000        ; a disk controller, see DISK_* below
BEEPER          = 0xFD009000

PIC_PENDING     = 0x00
PIC_ENABLE      = 0x04
PIC_ACTIVE      = 0x08
PIC_CLAIM       = 0x0C
IRQ_KBD         = 0
IRQ_UART        = 1
IRQ_TIMER       = 2
IRQ_DISK0       = 3
IRQ_DISK1       = 4
IRQ_VIDEO       = 5
IRQ_FLOPPY      = 6

KBD_STATUS      = 0x00
KBD_DATA        = 0x04
KBD_CONTROL     = 0x08
KBD_READY       = 1 << 0
KBD_OVERFLOW    = 1 << 1
KBD_FLUSH       = 1 << 0

UART_DATA       = 0x00
UART_STATUS     = 0x04
UART_CONTROL    = 0x08
UART_TX_READY   = 1 << 1
UART_FLUSH      = 1 << 0
HOST_ESCAPE     = 0x1B              ; Esc typed in the host terminal

TIMER_COUNT_LO  = 0x00
TIMER_COUNT_HI  = 0x04
TIMER_FREQUENCY = 0x08
TIMER_RELOAD    = 0x0C
TIMER_VALUE     = 0x10
TIMER_CONTROL   = 0x14
TIMER_STATUS    = 0x18
TIMER_ENABLE    = 1 << 0
TIMER_PERIODIC  = 1 << 1
TIMER_EXPIRED   = 1 << 0

POWER_OFF       = 0x00              ; write the exit code
POWER_RESET     = 0x04

DISK_STATUS     = 0x00
DISK_SECTORS    = 0x04
DISK_SECTOR     = 0x08
DISK_COUNT      = 0x0C
DISK_ADDRESS    = 0x10
DISK_COMMAND    = 0x14
DISK_ERROR      = 0x18
DISK_PRESENT    = 1 << 0            ; STATUS bits
DISK_READONLY   = 1 << 1
DISK_BUSY       = 1 << 2
DISK_DONE       = 1 << 3
DISK_FAILED     = 1 << 4
DISK_CHANGED    = 1 << 5            ; the floppy was inserted or ejected
DISK_READ       = 1                 ; commands
DISK_WRITE      = 2
DISK_ERR_COMMAND  = 1               ; ERROR codes
DISK_ERR_NO_DISK  = 2
DISK_ERR_RANGE    = 3
DISK_ERR_ADDRESS  = 4
DISK_ERR_READONLY = 5
DISK_ERR_MEDIA    = 6
SECTOR_SIZE     = 512

VIDEO_STATUS    = 0x00
VIDEO_CONTROL   = 0x04
VIDEO_MODE      = 0x08
VIDEO_WIDTH     = 0x0C
VIDEO_HEIGHT    = 0x10
VIDEO_BPP       = 0x14
VIDEO_PITCH     = 0x18
VIDEO_VRAM_SIZE = 0x1C
VIDEO_START     = 0x20
VIDEO_FRAME     = 0x24
VIDEO_PALETTE_INDEX = 0x28
VIDEO_PALETTE_DATA  = 0x2C
VIDEO_COMMAND   = 0x40
VIDEO_ERROR     = 0x44
VIDEO_DST_BASE  = 0x48
VIDEO_DST_PITCH = 0x4C
VIDEO_DST_XY    = 0x50              ; x | y << 16
VIDEO_SRC_BASE  = 0x54
VIDEO_SRC_PITCH = 0x58
VIDEO_SRC_XY    = 0x5C
VIDEO_SIZE      = 0x60              ; width | height << 16
VIDEO_FG        = 0x64
VIDEO_BG        = 0x68
VIDEO_ADDRESS   = 0x6C
VIDEO_COUNT     = 0x70
VIDEO_BUSY      = 1 << 0            ; STATUS bits
VIDEO_DONE      = 1 << 1
VIDEO_FAILED    = 1 << 2
VIDEO_VBLANK    = 1 << 3
VIDEO_ENABLE    = 1 << 0            ; CONTROL bits
VIDEO_DONE_IRQ  = 1 << 1
VIDEO_VBLANK_IRQ = 1 << 2
VIDEO_320X240   = 0                 ; MODE: resolution | depth
VIDEO_640X480   = 1
VIDEO_800X600   = 2
VIDEO_1024X768  = 3
VIDEO_1BPP      = 0 << 4
VIDEO_4BPP      = 1 << 4
VIDEO_8BPP      = 2 << 4
VIDEO_16BPP     = 3 << 4
VIDEO_32BPP     = 4 << 4
VIDEO_FILL      = 1                 ; commands
VIDEO_COPY      = 2
VIDEO_EXPAND    = 3
VIDEO_LOAD      = 4
VIDEO_STORE     = 5
VIDEO_TRANSPARENT = 1 << 8          ; EXPAND: 0 bits are left alone
VIDEO_MEMORY    = 1 << 9            ; EXPAND: the bitmap is in RAM or ROM
VIDEO_ERR_COMMAND = 1               ; ERROR codes
VIDEO_ERR_RANGE   = 2
VIDEO_ERR_ADDRESS = 3
VRAM_SIZE       = 0x400000

BEEPER_CONTROL  = 0x00
BEEPER_FREQUENCY = 0x04             ; Hz
BEEPER_DURATION = 0x08              ; ticks, 0 = until turned off
BEEPER_ON       = 1 << 0

STATUS_IE       = 1 << 0
STATUS_PUM      = 1 << 3            ; user mode after IRET
STATUS_EXL      = 1 << 4            ; in the handler: set on entry and at reset

CAUSE_SYSCALL   = 12
CAUSE_BREAK     = 13

; MMU (docs/INSTRUCTIONS.md#memory-management)
PTBR_EN         = 1 << 0
PTBR_ASID_SHIFT = 4
PTBR_ASID_MASK  = 0xFF << PTBR_ASID_SHIFT
PTE_V           = 1 << 0
PTE_R           = 1 << 1
PTE_W           = 1 << 2
PTE_X           = 1 << 3
PTE_U           = 1 << 4
PTE_A           = 1 << 5
PTE_D           = 1 << 6
PTE_G           = 1 << 7
PAGE_SIZE       = 0x1000
SUPERPAGE_SIZE  = 0x400000
DIR_IO          = (PIC >> 22) * 4       ; directory entry offsets
DIR_ROM         = (ROM_BASE >> 22) * 4

; boot protocol (docs/SPECIFICATION.md#boot-protocol)
BOOT_MAGIC      = 0x424D5257        ; "WRMB", first word of a boot image
BOOT_HDR_MAGIC   = 0x00             ; boot image header, at the load address
BOOT_HDR_SECTORS = 0x04             ; image size in sectors, from sector 0
BOOT_HDR_ENTRY   = 0x08             ; entry point, offset from BOOT_LOAD
BOOT_HDR_FLAGS   = 0x0C             ; must be 0
BOOT_INFO_MAGIC = 0x4F464E49        ; "INFO"
BI_MAGIC        = 0x00              ; boot info block, r1 at the entry
BI_SIZE         = 0x04              ; bytes of the block: later fields are new
BI_RAM_SIZE     = 0x08
BI_DISK         = 0x0C              ; the boot disk's controller
BI_DISK_SECTORS = 0x10
BI_IMAGE        = 0x14              ; = BOOT_LOAD
BI_IMAGE_SIZE   = 0x18
BI_CLOCK        = 0x1C              ; ticks per second
BOOT_INFO_SIZE  = 0x20
BOOT_INFO       = 0x00001000
BOOT_STACK_TOP  = 0x00010000
BOOT_LOAD       = 0x00010000

; USB HID usage IDs (page 0x07)
HID_A           = 0x04
HID_ESCAPE      = 0x29

; ---- RAM layout (slot 0, at least 1MB) --------------------------------------
; Variables sit below 8KB, so they are reached as offset(r0) with no base
; register at all. Booting from disk (BOOT_* above) uses the same RAM; the
; demos only run if it didn't boot.

VAR_IRQ_COUNT   = 0x0100
VAR_KEY_COUNT   = 0x0104
VAR_QUIT        = 0x0108
VAR_KERNEL_SP   = 0x010C            ; supervisor r30 while user code runs
VAR_TICKS       = 0x0110            ; timer interrupts taken
VAR_CON_X       = 0x0114            ; screen console cursor, in characters
VAR_CON_Y       = 0x0118
BUFFER          = 0x0200
IRQ_STACK_TOP   = 0x00080000
STACK_TOP       = 0x00100000

; screen console (video.asm): 80x30 characters in 640x480, 8 bpp; the
; font stays at the end of VRAM, past the frame of any mode
CON_MODE        = VIDEO_640X480 | VIDEO_8BPP
CON_PITCH       = 640
CON_COLS        = 80
CON_ROWS        = 30
CON_FG          = 7                 ; palette entries
CON_BG          = 0
FONT_VRAM       = VRAM_SIZE - 0x1000
FONT_SIZE       = 256 * 16
GLYPH_SIZE      = 16 << 16 | 8      ; for VIDEO_SIZE

; page tables and user memory of the MMU demo, physical addresses
PAGE_DIR        = 0x00010000
PAGE_TABLE1     = 0x00011000        ; virtual 0x00400000-0x007FFFFF
USER_DATA_PA    = 0x00012000
SPARE_PA        = 0x00013000
