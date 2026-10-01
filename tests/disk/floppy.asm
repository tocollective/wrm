; ============================================================================
;  Floppy drive: the disk controller at FLOPPY with its own IRQ line and
;  transfer rate, next to the hard disks
; ============================================================================
; @hdd 4
; @floppy 16
; The floppy holds a 16-sector pattern disk from tests/run.py (the word at
; byte offset o of sector s is s << 16 | o / 4), disk 0 a 4-sector one.

	.include "../common/harness.asm"

BUF             = 0x1000            ; 1 sector, reached as offset(r0)
FLOPPY_RATE     = 62500             ; bytes per second
IRQ_FLOPPY_BIT  = 1 << IRQ_FLOPPY

test_main:
	li r10, FLOPPY
	li r11, DISK0

	; ---- reset state: no CHANGED for the disk that was there at power-on
	li r28, 1
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT
	bne r4, r3, fail
	li r28, 2
	lw r4, DISK_SECTORS(r10)
	li r3, 16
	bne r4, r3, fail
	li r28, 3                   ; a drive of its own, not disk 0
	lw r4, DISK_SECTORS(r11)
	li r3, 4
	bne r4, r3, fail

	; ---- read sector 5: a word every W = FREQUENCY * 4 / 62500 ticks
	li r28, 4
	mfcr r12, cycle
	mv r1, r10
	li r2, DISK_READ
	li r3, 5
	li r4, 1
	li r5, BUF
	call disk_io
	mfcr r13, cycle
	bnez r1, fail
	li r28, 13                  ; a sector takes 128 * W ticks
	li r1, TIMER
	lw r3, TIMER_FREQUENCY(r1)
	shli r3, r3, 2
	li r1, FLOPPY_RATE
	divu r3, r3, r1
	shli r3, r3, 7
	sub r4, r13, r12
	bltu r4, r3, fail
	li r28, 14
	addi r3, r3, 256
	bgeu r4, r3, fail
	li r28, 5
	lw r4, BUF(r0)
	li r3, 0x00050000
	bne r4, r3, fail
	li r28, 6
	lw r4, BUF + SECTOR_SIZE - 4(r0)
	li r3, 0x0005007F
	bne r4, r3, fail

	; ---- DONE holds IRQ line 6 up until it is acknowledged
	li r28, 7
	li r1, 15
	sw r1, DISK_SECTOR(r10)
	li r1, 1
	sw r1, DISK_COUNT(r10)
	li r1, BUF
	sw r1, DISK_ADDRESS(r10)
	li r1, DISK_READ
	sw r1, DISK_COMMAND(r10)
.wait:
	lw r4, DISK_STATUS(r10)
	andi r3, r4, DISK_DONE
	beqz r3, .wait
	li r9, PIC
	lw r4, PIC_PENDING(r9)
	andi r4, r4, IRQ_FLOPPY_BIT
	beqz r4, fail
	li r28, 8
	lw r4, PIC_PENDING(r9)      ; ... and only line 6
	andi r4, r4, 1 << IRQ_DISK0
	bnez r4, fail
	li r28, 9
	li r1, DISK_DONE
	sw r1, DISK_STATUS(r10)
	lw r4, PIC_PENDING(r9)
	andi r4, r4, IRQ_FLOPPY_BIT
	bnez r4, fail
	li r28, 10
	lw r4, BUF(r0)
	li r3, 0x000F0000
	bne r4, r3, fail

	; ---- clearing CHANGED while it is clear changes nothing
	li r28, 11
	li r1, DISK_CHANGED
	sw r1, DISK_STATUS(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT
	bne r4, r3, fail

	; ---- the end of the floppy
	li r28, 12
	mv r1, r10
	li r2, DISK_READ
	li r3, 16
	li r4, 1
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_RANGE
	bne r1, r3, fail

	j pass
