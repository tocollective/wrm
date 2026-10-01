; ============================================================================
;  [7] MMU and user mode: the parts M can't express (see mmu.m)
; ============================================================================

MMU_STATUS_PUM  = 1 << 3
MMU_USER_CODE   = 0x00400000        ; where userPage is mapped
MMU_USER_DATA   = 0x00401000
MMU_USER_STACK  = MMU_USER_DATA + 0x1000
MMU_SYS_EXIT    = 0
MMU_SYS_PUTS    = 1                 ; r1 = zero-terminated string

; enterUser(entry: UWord): Void
; Saves the supervisor context in userContext (mmu.m) and enters user mode
; at entry. Returns when the user program exits: leaveUser comes back here.
enterUser:
	la r9, userContext
	sw r10, 0(r9)
	sw r11, 4(r9)
	sw r12, 8(r9)
	sw r13, 12(r9)
	sw r14, 16(r9)
	sw r15, 20(r9)
	sw r16, 24(r9)
	sw r17, 28(r9)
	sw r18, 32(r9)
	sw r19, 36(r9)
	sw r20, 40(r9)
	sw r21, 44(r9)
	sw r22, 48(r9)
	sw r23, 52(r9)
	sw r24, 56(r9)
	sw r25, 60(r9)
	sw r26, 64(r9)
	sw r27, 68(r9)
	sw fp, 72(r9)
	sw sp, 76(r9)
	sw ra, 80(r9)
	; IRET sets UM = PUM and jumps to EPC. PIE = 0 keeps interrupts off;
	; faults in user mode trap anyway.
	mtcr epc, r1
	li r2, MMU_STATUS_PUM
	mtcr status, r2
	iret

; leaveUser(): never returns
; Called by the trap handler on SYS_EXIT: drops the user context and the
; trap, and returns from enterUser in supervisor mode.
leaveUser:
	la r9, userContext
	lw r10, 0(r9)
	lw r11, 4(r9)
	lw r12, 8(r9)
	lw r13, 12(r9)
	lw r14, 16(r9)
	lw r15, 20(r9)
	lw r16, 24(r9)
	lw r17, 28(r9)
	lw r18, 32(r9)
	lw r19, 36(r9)
	lw r20, 40(r9)
	lw r21, 44(r9)
	lw r22, 48(r9)
	lw r23, 52(r9)
	lw r24, 56(r9)
	lw r25, 60(r9)
	lw r26, 64(r9)
	lw r27, 68(r9)
	lw fp, 72(r9)
	lw sp, 76(r9)
	lw ra, 80(r9)
	mtcr status, r0             ; EXL = 0, PUM = 0: stay in supervisor mode
	ret

; The user program: one ROM page, mapped at MMU_USER_CODE and run from
; there, so every address it uses is label + MMU_USER_DELTA. It is not M:
; M code would use the addresses of its strings in ROM, which user mode
; can't reach. Code and strings must fit in this page.
	.align 0x1000
userPage:
MMU_USER_DELTA = MMU_USER_CODE - userPage

	li sp, MMU_USER_STACK       ; the stack lives in the user data page
	li r9, MMU_SYS_PUTS
	la r1, u_hello + MMU_USER_DELTA
	syscall

	li r9, MMU_SYS_PUTS
	la r1, u_try_mfcr + MMU_USER_DELTA
	syscall
	mfcr r3, status             ; supervisor only: CAUSE = 11

	li r9, MMU_SYS_PUTS
	la r1, u_try_load + MMU_USER_DELTA
	syscall
	lw r3, 0x108(r0)            ; RAM page without U: CAUSE = 9

	li r9, MMU_SYS_PUTS
	la r1, u_try_store + MMU_USER_DELTA
	syscall
	li r4, MMU_USER_CODE
	sw r3, 0(r4)                ; code page has no W: CAUSE = 10

	li r9, MMU_SYS_PUTS
	la r1, u_bye + MMU_USER_DELTA
	syscall
	li r9, MMU_SYS_EXIT
	syscall

u_hello:        .asciz "user: hello from user mode\n"
u_try_mfcr:     .asciz "user: MFCR (supervisor only)\n"
u_try_load:     .asciz "user: LW from a supervisor page\n"
u_try_store:    .asciz "user: SW to the read-only code page\n"
u_bye:          .asciz "user: SYSCALL exit\n"
	.align 4
