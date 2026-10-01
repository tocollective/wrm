; ============================================================================
;  The parts of booting that M can't express: probing RAM through faults,
;  switching stacks and entering the image with the registers the boot
;  protocol sets (docs/SPECIFICATION.md#state-at-the-entry-point).
; ============================================================================

BOOT_ASM_INFO   = 0x00001000        ; the boot info block
BOOT_ASM_STACK  = 0x00010000        ; the image's stack, empty

; ramSize(): UWord -> bytes of RAM from address 0
; Slots are 1MB-32MB each and laid out back to back, so RAM ends at a 1MB
; boundary: loads from each boundary until one is a bus error. Borrows
; IVEC and runs with STATUS = 0 meanwhile, then restores both.
ramSize:
	mfcr r5, ivec
	mfcr r6, status
	la r2, .fault
	mtcr ivec, r2
	mtcr status, r0             ; EXL = 0: a bus error enters .fault
	li r1, 0
	li r3, 0x100000
	li r4, 4 * 0x2000000        ; four 32MB slots at most
.next:
	li r2, 0
	lw r7, 0(r1)                ; a bus error sets r2
	bnez r2, .end
	add r1, r1, r3
	bltu r1, r4, .next
.end:
	mtcr status, r6
	mtcr ivec, r5
	ret
.fault:
	li r2, 1
	mfcr r7, epc
	addi r7, r7, 4              ; skip the load
	mtcr epc, r7
	iret

; onStack(fn: (): Void, top: UWord): Void
; Calls fn with sp = top (8-aligned), then returns on the caller's stack.
onStack:
	addi sp, sp, -8
	sw ra, 4(sp)
	sw r10, 0(sp)
	mv r10, sp                  ; r10 survives the call
	mv sp, r2
	jalr ra, r1, 0
	mv sp, r10
	lw r10, 0(sp)
	lw ra, 4(sp)
	addi sp, sp, 8
	ret

; bootJump(entry: UWord): never returns
; r1 = the boot info block, r2 = 0, sp = an empty stack below the image,
; ra = 0; the rest of the state is already set by boot.m.
bootJump:
	mv r9, r1
	li r1, BOOT_ASM_INFO
	li r2, 0
	li sp, BOOT_ASM_STACK
	li ra, 0
	jr r9
