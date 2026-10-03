; ============================================================================
;  The parts of booting that M can't express: probing RAM and the devices
;  through faults,
;  switching stacks and entering the image with the registers the boot
;  protocol sets (docs/SPECIFICATION.md#state-at-the-entry-point).
; ============================================================================

BOOT_ASM_INFO   = 0x00001000        ; the boot info block
BOOT_ASM_STACK  = 0x00010000        ; the image's stack, empty
BOOT_ASM_IO     = 0xFD000000        ; the I/O region, one device a page
BOOT_ASM_IO_END = 0xFE000000
BOOT_ASM_ID     = 0xFFC             ; the ID register in a device's page

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

; probeDevices(table: UWord, max: UWord): UWord -> devices found
; Reads the ID register of each page of the I/O region; an unused page is
; a bus error. Lists the pages that answer at table as (address, ID)
; pairs, at most max of them. Borrows IVEC and STATUS like ramSize.
probeDevices:
	mfcr r5, ivec
	mfcr r6, status
	la r9, .fault
	mtcr ivec, r9
	mtcr status, r0             ; EXL = 0: a bus error enters .fault
	li r8, 0                    ; found
	li r3, BOOT_ASM_IO
.next:
	beqz r2, .end               ; the table is full
	li r7, 0
	lw r4, BOOT_ASM_ID(r3)      ; a bus error sets r7
	bnez r7, .skip
	sw r3, 0(r1)
	sw r4, 4(r1)
	addi r1, r1, 8
	addi r8, r8, 1
	addi r2, r2, -1
.skip:
	li r9, 0x1000
	add r3, r3, r9
	li r9, BOOT_ASM_IO_END
	bltu r3, r9, .next
.end:
	mtcr status, r6
	mtcr ivec, r5
	mv r1, r8
	ret
.fault:
	li r7, 1
	mfcr r9, epc
	addi r9, r9, 4              ; skip the load
	mtcr epc, r9
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
