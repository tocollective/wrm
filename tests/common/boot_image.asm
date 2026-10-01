; ============================================================================
;  Boot image for tests/disk/boot.asm (assembled at BOOT_LOAD by
;  tests/run.py): checks the state the firmware hands over
;  (docs/SPECIFICATION.md#boot-protocol) and reports like the harness,
;  "PASS" and exit code 0, or "FAIL: test N" and exit code N.
; ============================================================================

	.include "defs.asm"

RAM_SIZE        = 6 << 20           ; --ram 4M,2M
IMAGE_SIZE      = image_end - header

	.org BOOT_LOAD
header:
	.dw BOOT_MAGIC
	.dw IMAGE_SIZE / SECTOR_SIZE
	.dw entry - header
	.dw 0
	.dw 0xDEADBEEF              ; the entry doesn't have to follow the header

entry:
	mv r10, r1
	mv r11, r30

	li r28, 1
	li r3, BOOT_INFO
	bne r10, r3, fail
	li r28, 2
	li r3, BOOT_STACK_TOP
	bne r11, r3, fail
	li r28, 3
	mfcr r4, status
	li r3, STATUS_EXL
	bne r4, r3, fail
	li r28, 4
	mfcr r4, ivec
	bnez r4, fail
	li r28, 5
	mfcr r4, ptbr
	bnez r4, fail
	li r28, 6
	li r9, PIC
	lw r4, PIC_ENABLE(r9)
	bnez r4, fail
	li r28, 7                   ; the boot disk is idle and acknowledged
	li r9, DISK0
	lw r4, DISK_STATUS(r9)
	li r3, DISK_PRESENT
	bne r4, r3, fail

	; ---- the boot info block
	li r28, 10
	lw r4, BI_MAGIC(r10)
	li r3, BOOT_INFO_MAGIC
	bne r4, r3, fail
	li r28, 11
	lw r4, BI_SIZE(r10)
	li r3, BOOT_INFO_SIZE
	bne r4, r3, fail
	li r28, 12
	lw r4, BI_RAM_SIZE(r10)
	li r3, RAM_SIZE
	bne r4, r3, fail
	li r28, 13
	lw r4, BI_DISK(r10)
	li r3, DISK0
	bne r4, r3, fail
	li r28, 14                  ; the disk image is this image
	lw r4, BI_DISK_SECTORS(r10)
	li r3, IMAGE_SIZE / SECTOR_SIZE
	bne r4, r3, fail
	li r28, 15
	lw r4, BI_IMAGE(r10)
	li r3, BOOT_LOAD
	bne r4, r3, fail
	li r28, 16
	lw r4, BI_IMAGE_SIZE(r10)
	li r3, IMAGE_SIZE
	bne r4, r3, fail
	li r28, 17
	lw r4, BI_CLOCK(r10)
	li r9, TIMER
	lw r3, TIMER_FREQUENCY(r9)
	bne r4, r3, fail

	li r28, 18                  ; all of the image is loaded
	la r9, last_word
	lw r4, 0(r9)
	li r3, 0x600DB007
	bne r4, r3, fail

pass:
	la r1, s_pass
	call puts
	li r1, POWER
	sw r0, POWER_OFF(r1)
	hlt

fail:
	la r1, s_fail
	call puts
	mv r1, r28
	call print_dec
	li r1, '\n'
	call putc
	li r1, POWER
	sw r28, POWER_OFF(r1)
	hlt

	.include "lib.asm"

s_pass:         .asciz "PASS\n"
s_fail:         .asciz "FAIL: test "

	.align SECTOR_SIZE
	.space 2 * SECTOR_SIZE - 4  ; a few sectors, so the rest has to load
last_word:
	.dw 0x600DB007
image_end:
