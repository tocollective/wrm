; ============================================================================
;  Shared folder without --share: the device is there, every command
;  fails with error 2
; ============================================================================

	.include "../common/harness.asm"

test_main:
	li r10, SHARE

	li r28, 1
	lw r4, SHARE_STATUS(r10)
	bnez r4, fail
	li r28, 2
	lw r4, SHARE_HANDLES(r10)
	li r3, 16
	bne r4, r3, fail

	li r28, 3
	la r1, p_root
	sw r1, SHARE_PATH(r10)
	li r1, SH_STAT
	sw r1, SHARE_COMMAND(r10)
	lw r4, SHARE_ERROR(r10)
	li r3, SH_E_NO_FOLDER
	bne r4, r3, fail
	li r28, 4
	li r1, SH_CLOSE
	sw r1, SHARE_COMMAND(r10)
	lw r4, SHARE_ERROR(r10)
	li r3, SH_E_NO_FOLDER
	bne r4, r3, fail
	li r28, 5                   ; an unknown command is that first
	li r1, 99
	sw r1, SHARE_COMMAND(r10)
	lw r4, SHARE_ERROR(r10)
	li r3, SH_E_COMMAND
	bne r4, r3, fail
	li r28, 6                   ; the registers keep what is written
	li r1, 0x12345678
	sw r1, SHARE_COUNT(r10)
	lw r4, SHARE_COUNT(r10)
	bne r4, r1, fail

	j pass

p_root:         .asciz ""
