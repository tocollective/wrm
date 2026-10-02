; ============================================================================
;  Disk controller: registers, reads and writes through DMA, errors,
;  timing, the IRQ line
; ============================================================================
; @hdd 64
; Disk 0 is a 64-sector image from tests/run.py: the word at byte offset o
; of sector s is s << 16 | o / 4. Disk 1 has no image. RAM is 4MB.

	.include "../common/harness.asm"

BUF             = 0x1000            ; 3 sectors, reached as offset(r0)
WBUF            = 0x1800            ; 1 sector
IRQ_DISK0_BIT   = 1 << IRQ_DISK0

test_main:
	li r10, DISK0
	li r11, DISK1

	; ---- reset state
	li r28, 1
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT
	bne r4, r3, fail
	li r28, 2
	lw r4, DISK_SECTORS(r10)
	li r3, 64
	bne r4, r3, fail
	li r28, 3
	lw r4, DISK_ERROR(r10)
	bnez r4, fail
	lw r4, DISK_SECTOR(r10)
	bnez r4, fail
	lw r4, DISK_COUNT(r10)
	bnez r4, fail
	lw r4, DISK_ADDRESS(r10)
	bnez r4, fail

	; ---- registers keep what is written
	li r28, 4
	li r1, 0x1234
	sw r1, DISK_SECTOR(r10)
	lw r4, DISK_SECTOR(r10)
	bne r4, r1, fail
	li r28, 5
	sw r1, DISK_COUNT(r10)
	lw r4, DISK_COUNT(r10)
	bne r4, r1, fail
	li r28, 6
	sw r1, DISK_ADDRESS(r10)
	lw r4, DISK_ADDRESS(r10)
	bne r4, r1, fail
	li r28, 7                   ; read-only: writes are ignored
	sw r0, DISK_SECTORS(r10)
	lw r4, DISK_SECTORS(r10)
	li r3, 64
	bne r4, r3, fail
	li r28, 8                   ; COMMAND is write-only
	lw r4, DISK_COMMAND(r10)
	bnez r4, fail

	; ---- read sectors 3 and 4
	li r28, 10
	li r1, 3
	sw r1, DISK_SECTOR(r10)
	li r1, 2
	sw r1, DISK_COUNT(r10)
	li r1, BUF
	sw r1, DISK_ADDRESS(r10)
	li r1, DISK_READ
	sw r1, DISK_COMMAND(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT | DISK_BUSY
	bne r4, r3, fail
	li r28, 11                  ; writes are ignored while busy
	li r1, 50
	sw r1, DISK_SECTOR(r10)
	sw r1, DISK_COUNT(r10)
	sw r1, DISK_ADDRESS(r10)
	li r1, DISK_WRITE
	sw r1, DISK_COMMAND(r10)
	lw r4, DISK_SECTOR(r10)
	li r3, 3
	bne r4, r3, fail
	li r28, 12                  ; ADDRESS follows the words as they move
	lw r4, DISK_ADDRESS(r10)
	li r3, BUF
	bgeu r3, r4, fail
	li r3, BUF + 2 * SECTOR_SIZE
	bgeu r4, r3, fail
	li r28, 13
.wait:
	lw r4, DISK_STATUS(r10)
	andi r3, r4, DISK_DONE
	beqz r3, .wait
	li r3, DISK_PRESENT | DISK_DONE
	bne r4, r3, fail
	li r28, 14
	lw r4, DISK_ERROR(r10)
	bnez r4, fail
	li r28, 15                  ; SECTOR, COUNT, ADDRESS end past the transfer
	lw r4, DISK_SECTOR(r10)
	li r3, 5
	bne r4, r3, fail
	li r28, 16
	lw r4, DISK_COUNT(r10)
	bnez r4, fail
	li r28, 17
	lw r4, DISK_ADDRESS(r10)
	li r3, BUF + 2 * SECTOR_SIZE
	bne r4, r3, fail
	li r28, 18
	lw r4, BUF(r0)
	li r3, 0x00030000
	bne r4, r3, fail
	li r28, 19
	lw r4, BUF + SECTOR_SIZE - 4(r0)
	li r3, 0x0003007F
	bne r4, r3, fail
	li r28, 20
	lw r4, BUF + SECTOR_SIZE(r0)
	li r3, 0x00040000
	bne r4, r3, fail
	li r28, 21
	lw r4, BUF + 2 * SECTOR_SIZE - 4(r0)
	li r3, 0x0004007F
	bne r4, r3, fail

	; ---- DONE holds the IRQ line up until it is acknowledged
	li r28, 22
	li r9, PIC
	lw r4, PIC_PENDING(r9)
	andi r4, r4, IRQ_DISK0_BIT
	beqz r4, fail
	li r28, 23
	li r1, DISK_DONE
	sw r1, DISK_STATUS(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT
	bne r4, r3, fail
	li r28, 24
	lw r4, PIC_PENDING(r9)
	andi r4, r4, IRQ_DISK0_BIT
	bnez r4, fail

	; ---- one word per tick: a sector takes 128 ticks
	li r28, 25
	mfcr r12, cycle
	mv r1, r10
	li r2, DISK_READ
	li r3, 7
	li r4, 1
	li r5, BUF
	call disk_io
	mfcr r13, cycle
	bnez r1, fail
	li r28, 26
	sub r4, r13, r12
	li r3, SECTOR_SIZE / 4
	bltu r4, r3, fail
	li r28, 27
	li r3, SECTOR_SIZE / 4 + 64
	bgeu r4, r3, fail
	li r28, 28
	lw r4, BUF(r0)
	li r3, 0x00070000
	bne r4, r3, fail

	; ---- write sector 10, read 9-11 back
	li r1, WBUF
	li r2, 0xA5000000
	li r3, WBUF + SECTOR_SIZE
.fill:
	sw r2, 0(r1)
	addi r2, r2, 1
	addi r1, r1, 4
	bltu r1, r3, .fill
	li r28, 30
	mv r1, r10
	li r2, DISK_WRITE
	li r3, 10
	li r4, 1
	li r5, WBUF
	call disk_io
	bnez r1, fail
	li r28, 31
	mv r1, r10
	li r2, DISK_READ
	li r3, 9
	li r4, 3
	li r5, BUF
	call disk_io
	bnez r1, fail
	li r28, 32
	lw r4, BUF(r0)
	li r3, 0x00090000
	bne r4, r3, fail
	li r28, 33
	lw r4, BUF + SECTOR_SIZE(r0)
	li r3, 0xA5000000
	bne r4, r3, fail
	li r28, 34
	lw r4, BUF + 2 * SECTOR_SIZE - 4(r0)
	li r3, 0xA500007F
	bne r4, r3, fail
	li r28, 35
	lw r4, BUF + 2 * SECTOR_SIZE(r0)
	li r3, 0x000B0000
	bne r4, r3, fail

	; ---- a command that can't run ends at once and moves nothing
	li r28, 40                  ; past the end of the disk
	mv r1, r10
	li r2, DISK_READ
	li r3, 63
	li r4, 2
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_RANGE
	bne r1, r3, fail
	li r28, 41
	lw r4, DISK_SECTOR(r10)
	li r3, 63
	bne r4, r3, fail
	li r28, 42
	lw r4, DISK_COUNT(r10)
	li r3, 2
	bne r4, r3, fail
	li r28, 43                  ; SECTOR + COUNT wraps around
	mv r1, r10
	li r2, DISK_READ
	li r3, 0xFFFFFFFF
	li r4, 2
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_RANGE
	bne r1, r3, fail
	li r28, 44                  ; the last sector is fine
	mv r1, r10
	li r2, DISK_READ
	li r3, 63
	li r4, 1
	li r5, BUF
	call disk_io
	bnez r1, fail
	li r28, 45
	mv r1, r10
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, BUF + 2
	call disk_io
	li r3, DISK_ERR_ADDRESS
	bne r1, r3, fail
	li r28, 46
	mv r1, r10
	li r2, 5
	li r3, 0
	li r4, 1
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_COMMAND
	bne r1, r3, fail
	li r28, 47                  ; ERROR outlives the acknowledge
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT | DISK_FAILED
	bne r4, r3, fail
	li r28, 48                  ; ... until the next command
	sw r0, DISK_COUNT(r10)
	li r1, DISK_READ
	sw r1, DISK_COMMAND(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT | DISK_DONE
	bne r4, r3, fail
	li r28, 49                  ; COUNT = 0 is done at once
	lw r4, DISK_ERROR(r10)
	bnez r4, fail
	li r1, DISK_DONE
	sw r1, DISK_STATUS(r10)

	; ---- DMA reaches RAM only
	li r28, 50                  ; ROM
	mv r1, r10
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, ROM_BASE
	call disk_io
	li r3, DISK_ERR_ADDRESS
	bne r1, r3, fail
	li r28, 51
	lw r4, DISK_ADDRESS(r10)
	li r3, ROM_BASE
	bne r4, r3, fail
	li r28, 52                  ; the end of RAM, 64 words in
	mv r1, r10
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, RAM_END - SECTOR_SIZE / 2
	call disk_io
	li r3, DISK_ERR_ADDRESS
	bne r1, r3, fail
	li r28, 53
	lw r4, DISK_ADDRESS(r10)
	li r3, RAM_END
	bne r4, r3, fail
	li r28, 54
	lw r4, DISK_SECTOR(r10)
	bnez r4, fail
	li r28, 55
	lw r4, DISK_COUNT(r10)
	li r3, 1
	bne r4, r3, fail
	li r28, 56                  ; writing from the I/O region
	mv r1, r10
	li r2, DISK_WRITE
	li r3, 0
	li r4, 1
	li r5, PIC
	call disk_io
	li r3, DISK_ERR_ADDRESS
	bne r1, r3, fail
	li r28, 57                  ; ... left sector 0 alone
	mv r1, r10
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, BUF
	call disk_io
	bnez r1, fail
	li r28, 58
	lw r4, BUF(r0)
	bnez r4, fail
	lw r4, BUF + 4(r0)
	li r3, 1
	bne r4, r3, fail

	; ---- no image in disk 1
	li r28, 60
	lw r4, DISK_STATUS(r11)
	bnez r4, fail
	li r28, 61
	lw r4, DISK_SECTORS(r11)
	bnez r4, fail
	li r28, 62
	mv r1, r11
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_NO_DISK
	bne r1, r3, fail

	; ---- the IRQ: WFI with IE = 0 goes on once the line is up
	li r28, 70
	li r9, PIC
	li r1, IRQ_DISK0_BIT
	sw r1, PIC_ENABLE(r9)
	li r1, 1
	sw r1, DISK_SECTOR(r10)
	sw r1, DISK_COUNT(r10)
	li r1, BUF
	sw r1, DISK_ADDRESS(r10)
	li r1, DISK_READ
	sw r1, DISK_COMMAND(r10)
	wfi
	lw r4, DISK_STATUS(r10)
	andi r4, r4, DISK_DONE
	beqz r4, fail
	li r28, 71
	lw r4, PIC_CLAIM(r9)
	li r3, IRQ_DISK0
	bne r4, r3, fail
	li r28, 72
	lw r4, BUF(r0)
	li r3, 0x00010000
	bne r4, r3, fail
	li r1, DISK_DONE
	sw r1, DISK_STATUS(r10)
	sw r0, PIC_ENABLE(r9)

	j pass
