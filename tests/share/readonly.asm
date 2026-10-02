; ============================================================================
;  Shared folder, read-only (--share PATH:ro): reading works, every change
;  fails with error 6
; ============================================================================
; @share ro

	.include "../common/harness.asm"

BUF             = 0x0400

test_main:
	li r10, SHARE

	li r28, 1
	lw r4, SHARE_STATUS(r10)
	li r3, SHARE_PRESENT | SHARE_RO
	bne r4, r3, fail

	li r28, 2                   ; reading works
	la r1, p_hello
	sw r1, SHARE_PATH(r10)
	sw r0, SHARE_FLAGS(r10)
	li r1, SH_OPEN
	call command
	bnez r1, fail
	li r28, 3
	sw r0, SHARE_POS_LO(r10)
	sw r0, SHARE_POS_HI(r10)
	li r1, BUF
	sw r1, SHARE_ADDRESS(r10)
	li r1, 4
	sw r1, SHARE_COUNT(r10)
	li r1, SH_READ
	call command
	bnez r1, fail
	lw r4, BUF(r0)
	li r3, 0x6C6C6548           ; "Hell"
	bne r4, r3, fail
	li r28, 4                   ; SYNC of a read-only handle: nothing to do
	li r1, SH_SYNC
	call command
	bnez r1, fail
	li r1, SH_CLOSE
	call command
	bnez r1, fail

	li r28, 5                   ; OPEN to write
	li r1, SH_F_WRITE
	sw r1, SHARE_FLAGS(r10)
	li r1, SH_OPEN
	call command
	li r3, SH_E_READONLY
	bne r1, r3, fail
	li r28, 6
	la r1, p_new
	sw r1, SHARE_PATH(r10)
	li r1, SH_MKDIR
	call command
	li r3, SH_E_READONLY
	bne r1, r3, fail
	li r28, 7
	la r1, p_hello
	sw r1, SHARE_PATH(r10)
	li r1, SH_REMOVE
	call command
	li r3, SH_E_READONLY
	bne r1, r3, fail
	li r28, 8
	la r1, p_new
	sw r1, SHARE_PATH2(r10)
	li r1, SH_RENAME
	call command
	li r3, SH_E_READONLY
	bne r1, r3, fail
	li r28, 9                   ; hello.txt is still there
	la r1, p_hello
	sw r1, SHARE_PATH(r10)
	li r1, BUF
	sw r1, SHARE_ADDRESS(r10)
	li r1, SH_STAT_SIZE
	sw r1, SHARE_COUNT(r10)
	li r1, SH_STAT
	call command
	bnez r1, fail

	j pass

; command(r1 = command) -> r1 = ERROR
command:
	sw r1, SHARE_COMMAND(r10)
	lw r1, SHARE_ERROR(r10)
	ret

p_hello:        .asciz "hello.txt"
p_new:          .asciz "new"
