; ============================================================================
;  Device ID registers: every device's at offset 0xFFC of its page, read-
;  only; an unused page of the I/O region has none (bus error)
; ============================================================================

	.include "../common/harness.asm"

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0

	; ---- each device's ID, in address order
	li r28, 1
	la r10, devices
	la r11, devices_end
.next:
	lw r9, 0(r10)               ; the page
	lw r3, 4(r10)               ; its ID
	lw r4, IO_ID(r9)
	bne r4, r3, fail
	addi r28, r28, 1
	addi r10, r10, 8
	bltu r10, r11, .next
	bnez r24, fail

	; ---- read-only: a write is ignored, not a bus error
	li r28, 30
	li r9, TIMER
	li r1, -1
	sw r1, IO_ID(r9)
	lw r4, IO_ID(r9)
	li r3, ID_TIMER
	bne r4, r3, fail
	bnez r24, fail

	; ---- narrow reads see the low bits
	li r28, 31
	li r9, POWER
	lbu r4, IO_ID(r9)
	li r3, IRQ_POWER
	bne r4, r3, fail
	li r28, 32
	lhu r4, IO_ID(r9)
	li r3, ID_POWER & 0xFFFF
	bne r4, r3, fail

	; ---- the other offsets of the last word are not the register
	li r28, 33
	li r9, PIC
.f33:
	lw r4, 0xFF8(r9)            ; unmapped in the PIC
	li r1, 6                    ; load bus error
	la r2, .f33
	call check_trap

	; ---- unused pages: after the last device, and at the end of the region
	li r28, 34
	li r9, RTC + PAGE_SIZE
.f34:
	lw r4, IO_ID(r9)
	li r1, 6
	la r2, .f34
	call check_trap
	li r28, 35
	li r9, IO_END - PAGE_SIZE
.f35:
	lw r4, IO_ID(r9)
	li r1, 6
	la r2, .f35
	call check_trap
	li r28, 36                  ; writes there are bus errors too
.f36:
	sw r0, IO_ID(r9)
	li r1, 7                    ; store bus error
	la r2, .f36
	call check_trap
	j pass

; check_trap(r1 = CAUSE, r2 = EPC): exactly one trap was recorded since the
; last check and it matches; r4 = the mismatching value
check_trap:
	li r4, 1
	bne r24, r4, .count
	mv r4, r20
	bne r4, r1, fail
	mv r4, r21
	bne r4, r2, fail
	li r24, 0
	ret
.count:
	mv r4, r24
	j fail

; (page, ID) of every device
	.align 4
devices:
	.dw PIC, ID_PIC
	.dw KBD, ID_KBD
	.dw UART, ID_UART
	.dw TIMER, ID_TIMER
	.dw POWER, ID_POWER
	.dw DISK0, ID_DISK0
	.dw DISK1, ID_DISK1
	.dw VIDEO, ID_VIDEO
	.dw FLOPPY, ID_FLOPPY
	.dw BEEPER, ID_BEEPER
	.dw MOUSE, ID_MOUSE
	.dw NET, ID_NET
	.dw AUDIO, ID_AUDIO
	.dw RTC, ID_RTC
devices_end:
