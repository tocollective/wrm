; ============================================================================
;  Power controller: the state at power-on, the read-only registers, and a
;  reset by software that RESET_CAUSE reports. The host's request to power
;  off can't be made headless, so only its clear state is checked.
; ============================================================================

	.include "../common/harness.asm"

VAR_RESET_MARK  = 0x0120            ; RAM survives the reset
RESET_MARK      = 0x52534554        ; "TESR"

test_main:
	li r10, POWER
	lw r4, VAR_RESET_MARK(r0)
	li r3, RESET_MARK
	beq r4, r3, after_reset

	; ---- power-on: no request, the line low, started by power-on
	li r28, 1
	lw r4, POWER_STATUS(r10)
	bnez r4, fail
	li r28, 2
	lw r4, POWER_RESET_CAUSE(r10)
	li r3, RESET_POWER_ON
	bne r4, r3, fail
	li r28, 3
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_POWER
	and r4, r4, r3
	bnez r4, fail

	; ---- OFF and RESET read as 0
	li r28, 4
	lw r4, POWER_OFF(r10)
	bnez r4, fail
	lw r4, POWER_RESET(r10)
	bnez r4, fail

	; ---- only the host sets STATUS; RESET_CAUSE is read-only
	li r28, 5
	li r1, -1
	sw r1, POWER_STATUS(r10)
	lw r4, POWER_STATUS(r10)
	bnez r4, fail
	li r28, 6
	sw r1, POWER_RESET_CAUSE(r10)
	lw r4, POWER_RESET_CAUSE(r10)
	li r3, RESET_POWER_ON
	bne r4, r3, fail

	; ---- a reset by software: the store is the last thing that runs
	li r28, 7
	li r1, RESET_MARK
	sw r1, VAR_RESET_MARK(r0)
	sw r0, POWER_RESET(r10)
	j fail

after_reset:
	sw r0, VAR_RESET_MARK(r0)
	li r28, 8
	lw r4, POWER_RESET_CAUSE(r10)
	li r3, RESET_SOFTWARE
	bne r4, r3, fail
	li r28, 9
	lw r4, POWER_STATUS(r10)
	bnez r4, fail
	j pass
