; ============================================================================
;  Test harness, included first by every test ROM (see tests/run.py)
;
;  Starts at reset, sets the stack and IVEC and jumps to test_main, which
;  the test defines. A test ends by jumping (or branching) to:
;    pass      prints "PASS" and powers off with exit code 0
;    fail      prints "FAIL", the test number and r1-r4, and powers off
;              with the test number as the exit code (1-253)
;
;  Registers:
;    r28       number of the current check, set by the test (li r28, n);
;              it tells which check failed
;    r30       stack pointer, STACK_TOP at start
;  The rest is free for the test.
;
;  IVEC points at unexpected_trap until the test installs its own handler:
;  a trap that reaches it fails the test with exit code 254 (a fault only
;  traps once the test has written STATUS, clearing EXL). trap_record
;  is a ready-made handler for tests that expect faults.
;
;  The MMU tests keep RAM, the I/O region and the ROM mapped one to one,
;  so pass and fail work with translation on too. They don't work in
;  user mode: user code reports back through SYSCALL.
; ============================================================================

	.include "../../firmware/defs.asm"

FAIL_REGS       = 0x0080            ; r1-r4 saved by fail, 16 bytes
EXIT_TRAP       = 254               ; exit code of unexpected_trap

	.org ROM_BASE
reset:
	li r30, STACK_TOP
	la r1, unexpected_trap
	mtcr ivec, r1
	li r28, 0
	j test_main

; ---- results ------------------------------------------------------------------

pass:
	mtcr status, r0             ; no interrupts while reporting
	mtcr ptbr, r0               ; nor translation
	li r30, STACK_TOP
	la r1, s_pass
	call puts
	li r1, POWER
	sw r0, POWER_OFF(r1)
	hlt                         ; not reached

; "FAIL: test N, r1=... r2=... r3=... r4=..."
fail:
	mtcr status, r0
	mtcr ptbr, r0
	sw r1, FAIL_REGS + 0(r0)
	sw r2, FAIL_REGS + 4(r0)
	sw r3, FAIL_REGS + 8(r0)
	sw r4, FAIL_REGS + 12(r0)
	li r30, STACK_TOP
	la r1, s_fail
	call puts
	mv r1, r28
	call print_dec
	li r10, 0                   ; register index
.reg:
	la r1, s_fail_reg
	call puts
	addi r1, r10, '1'
	call putc
	li r1, '='
	call putc
	shli r2, r10, 2
	lw r1, FAIL_REGS(r2)
	li r2, 8
	call print_hex
	addi r10, r10, 1
	li r2, 4
	bltu r10, r2, .reg
	li r1, '\n'
	call putc

	mv r1, r28                  ; exit code: the test number, 1-253
	addi r2, r1, -1
	sltiu r2, r2, 253
	bnez r2, .exit
	li r1, 253
.exit:
	li r2, POWER
	sw r1, POWER_OFF(r2)
	hlt

; "FAIL: unexpected trap, cause=... epc=... badaddr=... in test N"
unexpected_trap:
	mtcr ptbr, r0
	li r30, STACK_TOP
	la r1, s_trap
	call puts
	la r1, s_cause
	mfcr r2, cause
	call print_field
	la r1, s_epc
	mfcr r2, epc
	call print_field
	la r1, s_badaddr
	mfcr r2, badaddr
	call print_field
	la r1, s_in_test
	call puts
	mv r1, r28
	call print_dec
	li r1, '\n'
	call putc
	li r1, POWER
	li r2, EXIT_TRAP
	sw r2, POWER_OFF(r1)
	hlt

; print_field(r1 = name, r2 = value): name, then the value in hex
print_field:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r2, 0(r30)
	call puts
	lw r1, 0(r30)
	li r2, 8
	call print_hex
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; ---- trap_record ----------------------------------------------------------------
; A handler for tests that expect faults. Set IVEC to it and write STATUS
; (STATUS.EXL is set at reset, and a fault with EXL set halts the CPU;
; e.g. STATUS_IE clears it). It records the trap:
;   r20 = CAUSE, r21 = EPC, r22 = BADADDR, r23 = STATUS on entry,
;   r24 += 1 (trap count)
; and returns to r25 if it is not zero (clearing r25), otherwise to the
; instruction after the faulting one. IRET restores IE and the mode.
; Only for faults: an interrupt would skip an instruction.

trap_record:
	mfcr r20, cause
	mfcr r21, epc
	mfcr r22, badaddr
	mfcr r23, status
	addi r24, r24, 1
	bnez r25, .resume
	addi r25, r21, 4
.resume:
	mtcr epc, r25
	li r25, 0
	iret

	.include "../../firmware/lib.asm"

s_pass:         .asciz "PASS\n"
s_fail:         .asciz "FAIL: test "
s_fail_reg:     .asciz ", r"
s_trap:         .asciz "FAIL: unexpected trap"
s_cause:        .asciz ", cause=0x"
s_epc:          .asciz ", epc=0x"
s_badaddr:      .asciz ", badaddr=0x"
s_in_test:      .asciz " in test "

	.align 4
