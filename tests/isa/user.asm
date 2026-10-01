; ============================================================================
;  User mode without the MMU: privileged instructions, SYSCALL, traps
;  from user mode, entering user mode through IRET and MTCR STATUS
; ============================================================================
; The handler logs every trap to RAM and returns to the instruction after
; the faulting one; SYSCALL with r1 = SYS_EXIT returns to r25 in supervisor
; mode instead. User code can't reach fail, so the checks read the log
; afterwards. The handler owns r20-r27.

	.include "../common/harness.asm"

LOG             = 0x1000            ; 4 words per trap
LOG_PTR         = 0x0100            ; next free log entry
SYS_EXIT        = 0x0E
STATUS_PIE      = 1 << 1
STATUS_UM       = 1 << 2

test_main:
	la r1, user_trap
	mtcr ivec, r1
	li r1, LOG
	sw r1, LOG_PTR(r0)

	; ---- enter user mode with IRET, IE clear
	la r25, .back
	li r1, STATUS_PUM
	mtcr status, r1
	la r1, user_prog
	mtcr epc, r1
	li r9, 0x77
	iret
	j fail
.back:
	; back in supervisor mode with IE = PIE = 0
	li r28, 1
	mfcr r4, status
	bnez r4, fail
	li r28, 2                   ; the counters are readable in user mode
	beqz r5, fail
	beqz r6, fail
	bnez r7, fail
	bnez r8, fail
	li r28, 3                   ; MFCR STATUS did not write r9
	li r3, 0x77
	bne r9, r3, fail
	li r28, 4                   ; user code can use all of physical memory
	lw r4, LOG + 0x800(r0)
	li r3, 0x600D
	bne r4, r3, fail

	; the log: every privileged instruction trapped with its own word
	li r10, LOG
	li r5, STATUS_PUM | STATUS_EXL ; STATUS in the handler: PUM, EXL, IE = PIE = 0
	li r28, 10
	li r1, 11
	la r2, u_hlt
	call check_log
	li r28, 11
	li r1, 11
	la r2, u_wfi
	call check_log
	li r28, 12
	li r1, 11
	la r2, u_iret
	call check_log
	li r28, 13
	li r1, 11
	la r2, u_mfcr
	call check_log
	li r28, 14
	li r1, 11
	la r2, u_mtcr
	call check_log
	li r28, 15
	li r1, 11
	la r2, u_tlbi
	call check_log
	li r28, 21                  ; CPUID is not a counter
	li r1, 11
	la r2, u_cpuid
	call check_log
	li r28, 22
	li r1, 11
	la r2, u_tlbi_all
	call check_log
	li r28, 16                  ; faults are handled in user mode with IE = 0
	li r1, 3
	la r2, u_misaligned
	li r3, 1
	call check_log_badaddr
	li r28, 17                  ; illegal is not privileged
	li r1, 1
	la r2, u_illegal
	call check_log
	li r28, 18                  ; SYSCALL returns to user mode
	li r1, CAUSE_SYSCALL
	la r2, u_syscall
	li r3, 0
	call check_log_badaddr
	li r28, 19
	li r1, CAUSE_SYSCALL
	la r2, u_exit
	li r3, 0
	call check_log_badaddr
	li r28, 20                  ; nothing else trapped
	lw r4, LOG_PTR(r0)
	bne r4, r10, fail

	; ---- enter user mode with IRET, IE set: the handler sees PIE
	li r28, 30
	la r25, .back2
	li r1, STATUS_PUM | STATUS_PIE
	mtcr status, r1
	la r1, user_exit
	mtcr epc, r1
	iret
	j fail
.back2:
	li r28, 31
	li r5, STATUS_PUM | STATUS_PIE | STATUS_EXL
	li r1, CAUSE_SYSCALL
	la r2, user_exit_syscall
	li r3, 0
	call check_log_badaddr
	li r28, 32                  ; IRET to supervisor: IE = PIE again
	mfcr r4, status
	li r3, STATUS_IE | STATUS_PIE
	bne r4, r3, fail
	mtcr status, r0

	; ---- MTCR STATUS sets UM: user mode from the next instruction
	li r28, 40
	la r25, .back3
	li r1, STATUS_UM
	mtcr status, r1
.mtcr_user:
	mfcr r4, status             ; privileged now
	li r1, SYS_EXIT
.mtcr_exit:
	syscall
	j fail
.back3:
	li r28, 41
	li r5, STATUS_PUM | STATUS_EXL
	li r1, 11
	la r2, .mtcr_user
	call check_log
	li r28, 42
	li r1, CAUSE_SYSCALL
	la r2, .mtcr_exit
	li r3, 0
	call check_log_badaddr
	li r28, 43
	mfcr r4, status
	bnez r4, fail
	j pass

; check_log(r1 = CAUSE, r2 = EPC, r5 = STATUS): the next log entry matches,
; with BADADDR = the instruction word at EPC; r4 = the mismatching value
check_log:
	lw r3, 0(r2)
; check_log_badaddr(r1 = CAUSE, r2 = EPC, r3 = BADADDR, r5 = STATUS)
check_log_badaddr:
	lw r4, 0(r10)
	bne r4, r1, fail
	lw r4, 4(r10)
	bne r4, r2, fail
	lw r4, 8(r10)
	bne r4, r3, fail
	lw r4, 12(r10)
	bne r4, r5, fail
	addi r10, r10, 16
	ret

; ---- the handler ----------------------------------------------------------------

user_trap:
	mfcr r20, cause
	mfcr r21, epc
	mfcr r22, badaddr
	mfcr r23, status
	lw r27, LOG_PTR(r0)
	sw r20, 0(r27)
	sw r21, 4(r27)
	sw r22, 8(r27)
	sw r23, 12(r27)
	addi r27, r27, 16
	sw r27, LOG_PTR(r0)
	addi r26, r21, 4            ; skip the faulting instruction
	li r27, CAUSE_SYSCALL
	bne r20, r27, .back
	li r27, SYS_EXIT
	bne r1, r27, .back
	andi r27, r23, STATUS_IE | STATUS_PIE | STATUS_EXL
	mtcr status, r27            ; PUM = 0: IRET stays in supervisor mode
	mv r26, r25
.back:
	mtcr epc, r26
	iret

; ---- user code ----------------------------------------------------------------

user_prog:
	mfcr r5, cycle
	mfcr r6, instret
	mfcr r7, cycleh
	mfcr r8, instreth
u_hlt:
	hlt
u_wfi:
	wfi
u_iret:
	iret
u_mfcr:
	mfcr r9, status
u_mtcr:
	mtcr scratch, r0
u_tlbi:
	tlbi r0
u_cpuid:
	mfcr r9, cpuid
u_tlbi_all:
	tlbi.all
u_misaligned:
	lw r9, 1(r0)
u_illegal:
	.dw 0x000000FF
	li r1, 0x600D
	sw r1, LOG + 0x800(r0)
	li r1, 5                    ; not SYS_EXIT
u_syscall:
	syscall
	li r1, SYS_EXIT
u_exit:
	syscall
	j fail                      ; not reached

user_exit:
	li r1, SYS_EXIT
user_exit_syscall:
	syscall
	j fail
