; ============================================================================
;  Disk controller: IDENTIFY, FLUSH and scatter-gather through a list of
;  descriptors (COMMAND.LIST)
; ============================================================================
; @hdd 16
; @args --hdd-serial 0=TESTSERIAL
; Disk 0 is a 16-sector image from tests/run.py: the word at byte offset o
; of sector s is s << 16 | o / 4. Disk 1 has no image. RAM is 4MB.

	.include "../common/harness.asm"

BUF             = 0x0200            ; 1 sector; all reached as offset(r0)
DESC            = 0x0400            ; descriptor lists
PIECE1          = 0x0800
PIECE2          = 0x1000
PIECE3          = 0x1800
SENTINEL        = 0x5A5A5A5A

test_main:
	li r10, DISK0
	li r11, DISK1

	; ---- IDENTIFY: one block to ADDRESS, SECTOR and COUNT stay
	li r28, 1
	mv r1, r10
	li r2, DISK_IDENTIFY
	li r3, 5
	li r4, 2
	li r5, BUF
	call disk_io
	bnez r1, fail
	li r28, 2
	lw r4, DISK_SECTOR(r10)
	li r3, 5
	bne r4, r3, fail
	lw r4, DISK_COUNT(r10)
	li r3, 2
	bne r4, r3, fail
	li r28, 3
	lw r4, DISK_ADDRESS(r10)
	li r3, BUF + SECTOR_SIZE
	bne r4, r3, fail
	li r28, 4
	lw r4, BUF(r0)
	li r3, IDENT_MAGIC
	bne r4, r3, fail
	lw r4, BUF + IDENT_VERSION(r0)
	li r3, 1
	bne r4, r3, fail
	li r28, 5
	lw r4, BUF + IDENT_SECTORS(r0)
	li r3, 16
	bne r4, r3, fail
	lw r4, BUF + IDENT_SECTOR_SIZE(r0)
	li r3, SECTOR_SIZE
	bne r4, r3, fail
	li r28, 6                   ; a writable hard disk
	lw r4, BUF + IDENT_FLAGS(r0)
	bnez r4, fail
	li r28, 7                   ; "TESTSERIAL", padded with zero bytes
	lw r4, BUF + IDENT_SERIAL(r0)
	li r3, 0x54534554           ; "TEST"
	bne r4, r3, fail
	lw r4, BUF + IDENT_SERIAL + 8(r0)
	li r3, 0x00004C41           ; "AL"
	bne r4, r3, fail
	lw r4, BUF + IDENT_SERIAL + 28(r0)
	bnez r4, fail
	li r28, 8                   ; "WRM.081632 hard disk"
	lw r4, BUF + IDENT_MODEL(r0)
	li r3, 0x2E4D5257           ; "WRM."
	bne r4, r3, fail
	li r28, 9                   ; UUID version 8, variant 10
	lbu r4, BUF + IDENT_UUID + 6(r0)
	andi r4, r4, 0xF0
	li r3, 0x80
	bne r4, r3, fail
	lbu r4, BUF + IDENT_UUID + 8(r0)
	andi r4, r4, 0xC0
	bne r4, r3, fail
	li r28, 10                  ; the rest is 0
	lw r4, BUF + SECTOR_SIZE - 4(r0)
	bnez r4, fail
	lw r4, BUF + 0x14(r0)
	bnez r4, fail
	li r28, 11                  ; no disk
	mv r1, r11
	li r2, DISK_IDENTIFY
	li r3, 0
	li r4, 0
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_NO_DISK
	bne r1, r3, fail

	; ---- FLUSH ends at once, without BUSY
	li r28, 20
	li r1, DISK_FLUSH
	sw r1, DISK_COMMAND(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT | DISK_DONE
	bne r4, r3, fail
	li r28, 21
	lw r4, DISK_ERROR(r10)
	bnez r4, fail
	li r1, DISK_DONE
	sw r1, DISK_STATUS(r10)
	li r28, 22                  ; no disk
	mv r1, r11
	li r2, DISK_FLUSH
	call disk_io
	li r3, DISK_ERR_NO_DISK
	bne r1, r3, fail
	li r28, 23                  ; FLUSH moves no data: LIST is an error
	mv r1, r10
	li r2, DISK_FLUSH | DISK_LISTED
	li r3, 0
	li r4, 1
	li r5, BUF
	call disk_io
	li r3, DISK_ERR_COMMAND
	bne r1, r3, fail
	li r28, 24                  ; other COMMAND bits are reserved
	mv r1, r10
	li r2, DISK_READ | 1 << 9
	call disk_io
	li r3, DISK_ERR_COMMAND
	bne r1, r3, fail

	; ---- LIST read: sectors 2 and 3 into three pieces
	li r28, 30
	li r1, SENTINEL
	sw r1, PIECE3 + 0x100(r0)
	li r9, DESC
	li r1, PIECE1
	sw r1, 0(r9)
	li r1, 0x100                ; words 0-0x3F of sector 2
	sw r1, 4(r9)
	li r1, PIECE2
	sw r1, 8(r9)
	li r1, 0x200                ; 0x40-0x7F of 2, 0-0x3F of 3
	sw r1, 12(r9)
	li r1, PIECE3
	sw r1, 16(r9)
	li r1, 0x400                ; 0x40-0x7F of 3, the rest unused
	sw r1, 20(r9)
	sw r9, DISK_LIST(r10)
	mv r1, r10
	li r2, DISK_READ | DISK_LISTED
	li r3, 2
	li r4, 2
	li r5, 0x12345678           ; not looked at
	call disk_io
	bnez r1, fail
	li r28, 31
	lw r4, PIECE1(r0)
	li r3, 0x00020000
	bne r4, r3, fail
	lw r4, PIECE1 + 0xFC(r0)
	li r3, 0x0002003F
	bne r4, r3, fail
	li r28, 32
	lw r4, PIECE2(r0)
	li r3, 0x00020040
	bne r4, r3, fail
	lw r4, PIECE2 + 0xFC(r0)
	li r3, 0x0002007F
	bne r4, r3, fail
	lw r4, PIECE2 + 0x100(r0)
	li r3, 0x00030000
	bne r4, r3, fail
	lw r4, PIECE2 + 0x1FC(r0)
	li r3, 0x0003003F
	bne r4, r3, fail
	li r28, 33
	lw r4, PIECE3(r0)
	li r3, 0x00030040
	bne r4, r3, fail
	lw r4, PIECE3 + 0xFC(r0)
	li r3, 0x0003007F
	bne r4, r3, fail
	lw r4, PIECE3 + 0x100(r0)
	li r3, SENTINEL
	bne r4, r3, fail
	li r28, 34                  ; the registers point just past it
	lw r4, DISK_LIST(r10)
	li r3, DESC + 24
	bne r4, r3, fail
	lw r4, DISK_ADDRESS(r10)
	li r3, PIECE3 + 0x100
	bne r4, r3, fail
	lw r4, DISK_SECTOR(r10)
	li r3, 4
	bne r4, r3, fail
	lw r4, DISK_COUNT(r10)
	bnez r4, fail

	; ---- LIST write: sector 8 gathered from two pieces
	li r28, 40
	li r2, 0xB0000000
	li r1, PIECE1
	li r3, PIECE1 + 0x80
.fill1:
	sw r2, 0(r1)
	addi r2, r2, 1
	addi r1, r1, 4
	bltu r1, r3, .fill1
	li r1, PIECE2
	li r3, PIECE2 + 0x180
.fill2:
	sw r2, 0(r1)
	addi r2, r2, 1
	addi r1, r1, 4
	bltu r1, r3, .fill2
	li r9, DESC
	li r1, PIECE1
	sw r1, 0(r9)
	li r1, 0x80
	sw r1, 4(r9)
	li r1, PIECE2
	sw r1, 8(r9)
	li r1, 0x180
	sw r1, 12(r9)
	sw r9, DISK_LIST(r10)
	mv r1, r10
	li r2, DISK_WRITE | DISK_LISTED
	li r3, 8
	li r4, 1
	call disk_io
	bnez r1, fail
	li r28, 41
	mv r1, r10
	li r2, DISK_READ
	li r3, 8
	li r4, 1
	li r5, BUF
	call disk_io
	bnez r1, fail
	li r28, 42
	lw r4, BUF(r0)
	li r3, 0xB0000000
	bne r4, r3, fail
	lw r4, BUF + 0x7C(r0)
	li r3, 0xB000001F
	bne r4, r3, fail
	lw r4, BUF + 0x80(r0)
	li r3, 0xB0000020
	bne r4, r3, fail
	lw r4, BUF + SECTOR_SIZE - 4(r0)
	li r3, 0xB000007F
	bne r4, r3, fail

	; ---- IDENTIFY through a list
	li r28, 45
	li r9, DESC
	li r1, PIECE1
	sw r1, 0(r9)
	li r1, SECTOR_SIZE
	sw r1, 4(r9)
	sw r9, DISK_LIST(r10)
	mv r1, r10
	li r2, DISK_IDENTIFY | DISK_LISTED
	call disk_io
	bnez r1, fail
	lw r4, PIECE1(r0)
	li r3, IDENT_MAGIC
	bne r4, r3, fail

	; ---- bad lists
	li r28, 50                  ; LIST not a multiple of 4: at once
	li r1, DESC + 2
	sw r1, DISK_LIST(r10)
	li r1, 0
	sw r1, DISK_COUNT(r10)
	li r1, DISK_READ | DISK_LISTED
	sw r1, DISK_COMMAND(r10)
	lw r4, DISK_STATUS(r10)
	li r3, DISK_PRESENT | DISK_DONE | DISK_FAILED
	bne r4, r3, fail
	lw r4, DISK_ERROR(r10)
	li r3, DISK_ERR_ADDRESS
	bne r4, r3, fail
	li r28, 51                  ; a length of 0
	li r9, DESC
	li r1, PIECE1
	sw r1, 0(r9)
	sw r0, 4(r9)
	sw r9, DISK_LIST(r10)
	mv r1, r10
	li r2, DISK_READ | DISK_LISTED
	li r3, 0
	li r4, 1
	call disk_io
	li r3, DISK_ERR_DESCRIPTOR
	bne r1, r3, fail
	li r28, 52                  ; LIST stays at the bad descriptor
	lw r4, DISK_LIST(r10)
	li r3, DESC
	bne r4, r3, fail
	li r28, 53                  ; an address not a multiple of 4
	li r1, PIECE1 + 2
	sw r1, 0(r9)
	li r1, SECTOR_SIZE
	sw r1, 4(r9)
	mv r1, r10
	li r2, DISK_READ | DISK_LISTED
	li r3, 0
	li r4, 1
	call disk_io
	li r3, DISK_ERR_DESCRIPTOR
	bne r1, r3, fail
	li r28, 54                  ; the second descriptor is bad: the first
	li r1, PIECE1               ; piece is read
	sw r1, 0(r9)
	li r1, 0x100
	sw r1, 4(r9)
	li r1, PIECE2
	sw r1, 8(r9)
	li r1, 6
	sw r1, 12(r9)
	mv r1, r10
	li r2, DISK_READ | DISK_LISTED
	li r3, 1
	li r4, 1
	call disk_io
	li r3, DISK_ERR_DESCRIPTOR
	bne r1, r3, fail
	li r28, 55
	lw r4, DISK_LIST(r10)
	li r3, DESC + 8
	bne r4, r3, fail
	lw r4, PIECE1 + 0xFC(r0)
	li r3, 0x0001003F
	bne r4, r3, fail
	li r28, 56                  ; the list in ROM
	li r1, ROM_BASE
	sw r1, DISK_LIST(r10)
	mv r1, r10
	li r2, DISK_READ | DISK_LISTED
	li r3, 0
	li r4, 1
	call disk_io
	li r3, DISK_ERR_ADDRESS
	bne r1, r3, fail
	lw r4, DISK_LIST(r10)
	li r3, ROM_BASE
	bne r4, r3, fail

	; ---- LIST keeps what is written
	li r28, 60
	li r1, DESC
	sw r1, DISK_LIST(r10)
	lw r4, DISK_LIST(r10)
	bne r4, r1, fail

	j pass
