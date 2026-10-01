; ============================================================================
;  Trap entry (m/docs/spec/07-hardware.md, 7.7): it starts with no free
;  register and can't trust sp, so it is assembly. It saves what an M
;  function may change (r1-r9, ra) and the interrupted sp in a TrapFrame
;  on its own stack, calls trap(frame) in trap.m, restores them and IRETs.
; ============================================================================

TRAP_STACK_TOP  = 0x00080000        ; in the first MB, below the main stack
TRAP_FRAME      = 48                ; sizeof(TrapFrame), rounded up to 8

trapEntry:
	mtcr scratch, sp            ; the interrupted stack pointer
	li sp, TRAP_STACK_TOP
	addi sp, sp, -TRAP_FRAME
	sw r1, 0(sp)
	sw r2, 4(sp)
	sw r3, 8(sp)
	sw r4, 12(sp)
	sw r5, 16(sp)
	sw r6, 20(sp)
	sw r7, 24(sp)
	sw r8, 28(sp)
	sw r9, 32(sp)
	sw ra, 36(sp)
	mfcr r1, scratch
	sw r1, 40(sp)
	mv r1, sp                   ; trap(frame)
	call trap
	lw ra, 36(sp)
	lw r9, 32(sp)
	lw r8, 28(sp)
	lw r7, 24(sp)
	lw r6, 20(sp)
	lw r5, 16(sp)
	lw r4, 12(sp)
	lw r3, 8(sp)
	lw r2, 4(sp)
	lw r1, 0(sp)
	lw sp, 40(sp)
	iret                        ; pc = EPC, IE = PIE, UM = PUM
