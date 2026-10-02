; ============================================================================
;  A reset by software (POWER RESET): the CPU and every device start over
;  as at power-on, RAM and VRAM keep what they held. The keyboard and the
;  UART get input before the reset from the input script.
; ============================================================================
; @hdd 4
; @input 0 key 4 down
; @input 0 uart x

	.include "../common/harness.asm"

VAR_PATTERN     = 0x1000            ; 64 words that survive the reset
PATTERN_WORDS   = 64
VAR_VRAM        = 0x1100            ; VRAM word 0, copied back after it
VRAM_WORD       = 0x00ABCDEF

test_main:
	li r10, POWER
	lw r4, POWER_RESET_CAUSE(r10)
	li r3, RESET_SOFTWARE
	beq r4, r3, after_reset

	; ---- the input reached the devices before the program ran
	li r28, 1
	li r1, KBD
	lw r4, KBD_STATUS(r1)
	andi r4, r4, KBD_READY
	beqz r4, fail
	li r28, 2
	li r1, UART
	lw r4, UART_STATUS(r1)
	andi r4, r4, UART_RX_READY
	beqz r4, fail

	; ---- a pattern in RAM
	li r1, VAR_PATTERN
	li r2, PATTERN_WORDS
	li r3, 0x01020304
.fill:
	sw r3, 0(r1)
	addi r1, r1, 4
	addi r3, r3, 0x111
	addi r2, r2, -1
	bnez r2, .fill

	; ---- a pixel in VRAM: FILL in 32 bpp
	li r28, 3
	li r1, VIDEO
	li r2, VIDEO_320X240 | VIDEO_32BPP
	sw r2, VIDEO_MODE(r1)
	li r2, VIDEO_ENABLE
	sw r2, VIDEO_CONTROL(r1)
	sw r0, VIDEO_DST_BASE(r1)
	li r2, 4
	sw r2, VIDEO_DST_PITCH(r1)
	sw r0, VIDEO_DST_XY(r1)
	li r2, 1 | 1 << 16
	sw r2, VIDEO_SIZE(r1)
	li r2, VRAM_WORD
	sw r2, VIDEO_FG(r1)
	li r2, VIDEO_FILL
	sw r2, VIDEO_COMMAND(r1)
	lw r4, VIDEO_STATUS(r1)
	andi r4, r4, VIDEO_FAILED
	bnez r4, fail

	; ---- every device away from its reset state
	li r1, PIC
	li r2, 1 << IRQ_TIMER | 1 << IRQ_RTC
	sw r2, PIC_ENABLE(r1)
	li r1, TIMER
	li r2, 1000
	sw r2, TIMER_RELOAD(r1)
	li r2, TIMER_ENABLE | TIMER_PERIODIC
	sw r2, TIMER_CONTROL(r1)
	li r1, DISK0
	li r2, 3
	sw r2, DISK_SECTOR(r1)
	li r2, 0x1000
	sw r2, DISK_ADDRESS(r1)
	li r1, BEEPER
	li r2, 440
	sw r2, BEEPER_FREQUENCY(r1)
	li r2, BEEPER_ON
	sw r2, BEEPER_CONTROL(r1)
	li r1, MOUSE
	li r2, MOUSE_ENABLE
	sw r2, MOUSE_CONTROL(r1)
	li r1, AUDIO
	li r2, 0xFFFF
	sw r2, AUDIO_MASTER(r1)
	li r1, RTC
	li r2, 0x7FFFFFFF               ; far in the future
	sw r2, RTC_ALARM_HI(r1)
	li r2, RTC_ARMED
	sw r2, RTC_CONTROL(r1)

	; ---- and the CPU's control registers (EXL is still set: the trigger
	; can't match)
	li r2, 0x5A5A5A5A
	mtcr scratch, r2
	li r2, 0x00012340               ; an ASID, translation off
	mtcr ptbr, r2
	li r2, TCTRL_W
	mtcr tctrl1, r2

	; ---- reset: the store is the last thing that runs
	li r28, 4
	sw r0, POWER_RESET(r10)
	j fail

after_reset:
	; ---- the CPU: as after power-on (the harness only set IVEC)
	li r28, 10
	mfcr r4, status
	li r3, STATUS_EXL
	bne r4, r3, fail
	li r28, 11
	mfcr r4, scratch
	bnez r4, fail
	mfcr r4, ptbr
	bnez r4, fail
	mfcr r4, tctrl1
	bnez r4, fail
	li r28, 12                      ; the counters started again
	mfcr r4, instret
	li r3, 64
	bgeu r4, r3, fail

	; ---- RAM kept the pattern
	li r28, 20
	li r1, VAR_PATTERN
	li r2, PATTERN_WORDS
	li r3, 0x01020304
.check:
	lw r4, 0(r1)
	bne r4, r3, fail
	addi r1, r1, 4
	addi r3, r3, 0x111
	addi r2, r2, -1
	bnez r2, .check

	; ---- the devices
	li r28, 30
	li r1, PIC
	lw r4, PIC_ENABLE(r1)
	bnez r4, fail
	li r28, 31
	li r1, TIMER
	lw r4, TIMER_CONTROL(r1)
	bnez r4, fail
	lw r4, TIMER_RELOAD(r1)
	bnez r4, fail
	lw r4, TIMER_STATUS(r1)
	bnez r4, fail
	li r28, 32                      ; COUNT started again too
	lw r4, TIMER_COUNT_HI(r1)
	bnez r4, fail
	lw r4, TIMER_COUNT_LO(r1)
	li r3, 100000
	bgeu r4, r3, fail
	li r28, 33
	li r1, KBD
	lw r4, KBD_STATUS(r1)
	bnez r4, fail
	li r28, 34
	li r1, UART
	lw r4, UART_STATUS(r1)
	li r3, UART_TX_READY
	bne r4, r3, fail
	li r28, 35
	li r1, DISK0
	lw r4, DISK_SECTOR(r1)
	bnez r4, fail
	lw r4, DISK_ADDRESS(r1)
	bnez r4, fail
	lw r4, DISK_STATUS(r1)
	li r3, DISK_PRESENT             ; the disk is still there
	bne r4, r3, fail
	li r28, 36
	li r1, BEEPER
	lw r4, BEEPER_CONTROL(r1)
	bnez r4, fail
	lw r4, BEEPER_FREQUENCY(r1)
	bnez r4, fail
	li r28, 37
	li r1, MOUSE
	lw r4, MOUSE_CONTROL(r1)
	bnez r4, fail
	li r28, 38
	li r1, AUDIO
	lw r4, AUDIO_MASTER(r1)
	bnez r4, fail
	li r28, 39
	li r1, RTC
	lw r4, RTC_CONTROL(r1)
	bnez r4, fail
	lw r4, RTC_ALARM_HI(r1)
	bnez r4, fail
	li r28, 40
	li r1, PIC                      ; no line is up
	lw r4, PIC_PENDING(r1)
	bnez r4, fail

	; ---- the video card: registers cleared, VRAM kept
	li r28, 50
	li r1, VIDEO
	lw r4, VIDEO_CONTROL(r1)
	bnez r4, fail
	lw r4, VIDEO_MODE(r1)
	bnez r4, fail
	li r28, 51
	sw r0, VIDEO_SRC_BASE(r1)
	li r2, VAR_VRAM
	sw r2, VIDEO_ADDRESS(r1)
	li r2, 4
	sw r2, VIDEO_COUNT(r1)
	li r2, VIDEO_STORE
	sw r2, VIDEO_COMMAND(r1)
.store:
	lw r4, VIDEO_STATUS(r1)
	andi r4, r4, VIDEO_BUSY
	bnez r4, .store
	lw r4, VIDEO_STATUS(r1)
	andi r4, r4, VIDEO_FAILED
	bnez r4, fail
	li r28, 52
	lw r4, VAR_VRAM(r0)
	li r3, VRAM_WORD
	bne r4, r3, fail

	j pass
