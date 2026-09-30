; ============================================================================
;  Definitions shared by the whole firmware: hardware constants and the
;  RAM layout. Constants only, no code or data.
; ============================================================================

; ---- memory map (docs/SPECIFICATION.md) ------------------------------------

ROM_BASE        = 0xFE000000
PIC             = 0xFD000000
KBD             = 0xFD001000
UART            = 0xFD002000
TIMER           = 0xFD003000
POWER           = 0xFD004000

PIC_PENDING     = 0x00
PIC_ENABLE      = 0x04
PIC_ACTIVE      = 0x08
PIC_CLAIM       = 0x0C
IRQ_KBD         = 0
IRQ_UART        = 1
IRQ_TIMER       = 2

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

STATUS_IE       = 1 << 0
STATUS_PUM      = 1 << 3            ; user mode after IRET

CAUSE_SYSCALL   = 12

; MMU (docs/INSTRUCTIONS.md#memory-management)
PTBR_EN         = 1 << 0
PTE_V           = 1 << 0
PTE_R           = 1 << 1
PTE_W           = 1 << 2
PTE_X           = 1 << 3
PTE_U           = 1 << 4
PAGE_SIZE       = 0x1000
SUPERPAGE_SIZE  = 0x400000
DIR_IO          = (PIC >> 22) * 4       ; directory entry offsets
DIR_ROM         = (ROM_BASE >> 22) * 4

; USB HID usage IDs (page 0x07)
HID_A           = 0x04
HID_ESCAPE      = 0x29

; ---- RAM layout (slot 0, at least 1MB) --------------------------------------
; Variables sit below 8KB, so they are reached as offset(r0) with no base
; register at all.

VAR_IRQ_COUNT   = 0x0100
VAR_KEY_COUNT   = 0x0104
VAR_QUIT        = 0x0108
VAR_KERNEL_SP   = 0x010C            ; supervisor r30 while user code runs
VAR_TICKS       = 0x0110            ; timer interrupts taken
BUFFER          = 0x0200
IRQ_STACK_TOP   = 0x00080000
STACK_TOP       = 0x00100000

; page tables and user memory of the MMU demo, physical addresses
PAGE_DIR        = 0x00010000
PAGE_TABLE1     = 0x00011000        ; virtual 0x00400000-0x007FFFFF
USER_DATA_PA    = 0x00012000
SPARE_PA        = 0x00013000
