; ============================================================================
;  [7] MMU and user mode
; ============================================================================
; The supervisor keeps its view of the machine through 4MB superpages
; mapped one to one (RAM: RW, I/O: RW, ROM: RX), none of them with U.
; The user program gets its own two pages at 0x00400000:
;   USER_CODE -> user_page in ROM   R X U
;   USER_DATA -> USER_DATA_PA       R W U   (its stack)

; user address space and system calls of this demo
; (the physical pages it uses are in defs.asm)
USER_CODE       = 0x00400000        ; -> user_page in ROM
USER_DATA       = 0x00401000        ; -> USER_DATA_PA
USER_STACK_TOP  = USER_DATA + PAGE_SIZE
DIR_USER        = (USER_CODE >> 22) * 4

; r9 = number, r1 = argument (docs/ABI.md#system-calls)
SYS_EXIT        = 0
SYS_PUTS        = 1                 ; r1 = zero-terminated string

demo_mmu:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_mmu_title
	call puts

	; clear the directory and the page table right after it
	li r1, PAGE_DIR
	li r2, PAGE_DIR + 2 * PAGE_SIZE
.clear:
	sw r0, 0(r1)
	addi r1, r1, 4
	bltu r1, r2, .clear

	; supervisor superpages
	li r9, PAGE_DIR
	li r2, 0x00000000 | PTE_V | PTE_R | PTE_W
	sw r2, 0(r9)                ; RAM
	li r2, PIC | PTE_V | PTE_R | PTE_W
	sw r2, DIR_IO(r9)           ; devices
	li r9, PAGE_DIR + DIR_ROM
	li r2, ROM_BASE | PTE_V | PTE_R | PTE_X
	li r3, PAGE_DIR + PAGE_SIZE
	li r4, SUPERPAGE_SIZE
.rom:
	sw r2, 0(r9)                ; 8 superpages for the 32MB ROM
	add r2, r2, r4
	addi r9, r9, 4
	bltu r9, r3, .rom

	; the user pages go through a page table: no R, W or X in the
	; directory entry means "pointer to a table"
	li r9, PAGE_DIR
	li r2, PAGE_TABLE1 | PTE_V
	sw r2, DIR_USER(r9)
	li r9, PAGE_TABLE1
	la r2, user_page | PTE_V | PTE_R | PTE_X | PTE_U
	sw r2, 0(r9)
	li r2, USER_DATA_PA | PTE_V | PTE_R | PTE_W | PTE_U
	sw r2, 4(r9)

	la r1, trap_handler
	mtcr ivec, r1
	li r2, PAGE_DIR | PTBR_EN
	mtcr ptbr, r2               ; translation on from the next instruction
	la r1, s_ptbr
	mfcr r2, ptbr
	call show

	; one virtual page, two physical ones: remapping needs TLBI
	li r9, USER_DATA_PA
	li r2, 0x1111
	sw r2, 0(r9)
	li r9, SPARE_PA
	li r2, 0x2222
	sw r2, 0(r9)
	la r1, s_va_read
	li r9, USER_DATA
	lw r2, 0(r9)                ; through USER_DATA_PA, now cached in the TLB
	call show
	li r9, PAGE_TABLE1
	li r2, SPARE_PA | PTE_V | PTE_R | PTE_W | PTE_U
	sw r2, 4(r9)
	li r9, USER_DATA
	tlbi r9                     ; drop the stale translation
	la r1, s_va_remap
	lw r2, 0(r9)                ; now through SPARE_PA
	call show
	li r9, PAGE_TABLE1
	li r2, USER_DATA_PA | PTE_V | PTE_R | PTE_W | PTE_U
	sw r2, 4(r9)
	li r9, USER_DATA
	tlbi r9

	; enter user mode: IRET sets UM = PUM and jumps to EPC.
	; PIE = 0 keeps interrupts off; faults in user mode trap anyway.
	sw r30, VAR_KERNEL_SP(r0)
	la r1, user_entry + USER_DELTA
	mtcr epc, r1
	li r2, STATUS_PUM
	mtcr status, r2
	iret

.back:                          ; SYS_EXIT returns here, r30 restored
	la r1, s_mmu_back
	mfcr r2, status
	call show
	mtcr ptbr, r0               ; translation off again

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; Faults and system calls from the user program. The CPU enters in
; supervisor mode with EPC = the faulting instruction or the SYSCALL;
; supervisor code may read user pages, so strings are passed by address.
trap_handler:
	mtcr scratch, r30           ; stash the user stack pointer
	li r30, IRQ_STACK_TOP
	addi r30, r30, -40
	sw r1, 0(r30)
	sw r2, 4(r30)
	sw r3, 8(r30)
	sw r4, 12(r30)
	sw r5, 16(r30)
	sw r6, 20(r30)
	sw r7, 24(r30)
	sw r8, 28(r30)
	sw r9, 32(r30)
	sw ra, 36(r30)

	mfcr r2, cause
	li r3, CAUSE_SYSCALL
	beq r2, r3, .syscall

	; a fault: report it and skip the instruction
	la r1, s_trap_cause
	call show
	la r1, s_trap_epc
	mfcr r2, epc
	call show
	la r1, s_trap_badaddr
	mfcr r2, badaddr
	call show
	j .skip

.syscall:
	lw r1, 32(r30)              ; user r9: number
	li r2, SYS_EXIT
	beq r1, r2, .exit
	li r2, SYS_PUTS
	bne r1, r2, .skip           ; unknown calls are ignored
	lw r1, 0(r30)               ; user r1: string
	call puts

.skip:
	mfcr r1, epc
	addi r1, r1, 4              ; continue after the instruction
	mtcr epc, r1
	lw ra, 36(r30)
	lw r9, 32(r30)
	lw r8, 28(r30)
	lw r7, 24(r30)
	lw r6, 20(r30)
	lw r5, 16(r30)
	lw r4, 12(r30)
	lw r3, 8(r30)
	lw r2, 4(r30)
	lw r1, 0(r30)
	mfcr r30, scratch
	iret                        ; back to user mode: UM = PUM = 1

.exit:
	; resume demo_mmu in supervisor mode, dropping the user context
	la r1, demo_mmu.back
	mtcr epc, r1
	li r1, STATUS_EXL           ; PUM = 0: IRET stays in supervisor mode
	mtcr status, r1
	lw r30, VAR_KERNEL_SP(r0)
	iret

; The user program: one ROM page, mapped at USER_CODE and run from there,
; so every address it uses is label + USER_DELTA. Code and strings must
; fit in this page.
	.align PAGE_SIZE
user_page:
USER_DELTA = USER_CODE - user_page

user_entry:
	li r30, USER_STACK_TOP      ; the stack lives in the user data page
	li r9, SYS_PUTS
	la r1, u_hello + USER_DELTA
	syscall

	li r9, SYS_PUTS
	la r1, u_try_mfcr + USER_DELTA
	syscall
	mfcr r3, status             ; supervisor only: CAUSE = 11

	li r9, SYS_PUTS
	la r1, u_try_load + USER_DELTA
	syscall
	lw r3, VAR_QUIT(r0)         ; RAM page without U: CAUSE = 9

	li r9, SYS_PUTS
	la r1, u_try_store + USER_DELTA
	syscall
	li r4, USER_CODE
	sw r3, 0(r4)                ; code page has no W: CAUSE = 10

	li r9, SYS_PUTS
	la r1, u_bye + USER_DELTA
	syscall
	li r9, SYS_EXIT
	syscall

u_hello:        .asciz "user: hello from user mode\n"
u_try_mfcr:     .asciz "user: MFCR (supervisor only)\n"
u_try_load:     .asciz "user: LW from a supervisor page\n"
u_try_store:    .asciz "user: SW to the read-only code page\n"
u_bye:          .asciz "user: SYSCALL exit\n"
	.align 4

; ---- data -----------------------------------------------------------------

s_mmu_title:    .asciz "\n[7] MMU and user mode\n"
s_ptbr:         .asciz "PTBR"
s_va_read:      .asciz "LW 0x00401000"
s_va_remap:     .asciz "remap + TLBI, LW again"
s_trap_cause:   .asciz "  trap: CAUSE"
s_trap_epc:     .asciz "        EPC"
s_trap_badaddr: .asciz "        BADADDR"
s_mmu_back:     .asciz "back in supervisor, STATUS"

	.align 4
