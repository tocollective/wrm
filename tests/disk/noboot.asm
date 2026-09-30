; ============================================================================
;  Boot protocol: boot returns when disk 0 holds no boot image
; ============================================================================
; @hdd 4
; Sector 0 of a pattern disk starts with 0, not BOOT_MAGIC.

	.include "../common/harness.asm"
	.include "../../firmware/boot.asm"

test_main:
	li r10, 0x1010
	li r11, 0x1111
	li r12, 0x1212
	li r28, 1
	call boot
	li r3, STACK_TOP
	bne r30, r3, fail
	li r28, 2                   ; preserved registers are preserved
	li r3, 0x1010
	bne r10, r3, fail
	li r3, 0x1111
	bne r11, r3, fail
	li r3, 0x1212
	bne r12, r3, fail
	li r28, 3
	mfcr r4, status
	li r3, STATUS_EXL
	bne r4, r3, fail
	j pass
