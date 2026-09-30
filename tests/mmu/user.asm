; ============================================================================
;  MMU in user mode: the U bit
; ============================================================================
; User code runs from USER_VA, a superpage with U over the start of ROM, so
; its own labels are at label - ROM_BASE + USER_VA; the one-to-one ROM,
; RAM and I/O mappings have no U. The handler logs every trap and skips
; the faulting instruction; a fetch fault returns to r31 instead, and
; SYSCALL with r1 = SYS_EXIT returns to r25 in supervisor mode.

	.include "../common/harness.asm"
	.include "../common/mmu.asm"

USER_VA         = 0x40000000
LOG             = 0x1000            ; 4 words per trap
LOG_PTR         = 0x0100
SYS_EXIT        = 0x0E
STATUS_PIE      = 1 << 1

test_main:
	la r1, user_trap
	mtcr ivec, r1
	li r1, LOG
	sw r1, LOG_PTR(r0)

	li r1, DIR
	call mmu_init
	li r1, TABLE
	call clear_page
	li r1, DIR
	li r2, USER_VA
	li r3, ROM_BASE | PTE_V | PTE_R | PTE_X | PTE_U
	call map_dir
	li r2, VA_T
	li r3, TABLE | PTE_V        ; U only matters in the entry that maps
	call map_dir
	li r1, TABLE
	li r2, VA_T
	li r3, PAGE0 | PTE_RW | PTE_U
	call map_page
	li r2, VA_T + 0x1000
	li r3, PAGE1 | PTE_RW       ; supervisor only
	call map_page
	li r2, VA_T + 0x2000
	li r3, PAGE2 | PTE_V | PTE_R | PTE_U
	call map_page
	li r1, 0x0000AAAA
	li r2, PAGE0
	sw r1, 0(r2)
	li r1, 0x0000CCCC
	li r2, PAGE2
	sw r1, 0(r2)
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1

	; ---- run the user program
	la r25, .back
	li r1, STATUS_PUM
	mtcr status, r1
	li r1, user_prog - ROM_BASE + USER_VA
	mtcr epc, r1
	iret
	j fail
.back:
	li r28, 1                   ; what the user program could do
	li r3, 0x0000AAAA
	bne r5, r3, fail
	li r28, 2
	li r1, PAGE0
	lw r4, 4(r1)
	li r3, 0x0000AAAB
	bne r4, r3, fail
	li r28, 3
	li r3, 0x0000CCCC
	bne r7, r3, fail
	li r28, 4
	beqz r8, fail               ; MFCR CYCLE
	li r28, 5                   ; what it couldn't: r6 was never written
	li r3, 0x66
	bne r6, r3, fail
	li r28, 6
	li r1, PAGE1
	lw r4, 4(r1)
	bnez r4, fail

	; ---- the log
	li r10, LOG
	li r28, 10                  ; supervisor-only page
	li r1, 9
	li r2, u_super - ROM_BASE + USER_VA
	li r3, VA_T + 0x1000
	call check_log
	li r28, 11
	li r1, 10
	li r2, u_super_st - ROM_BASE + USER_VA
	li r3, VA_T + 0x1004
	call check_log
	li r28, 12                  ; read-only page
	li r1, 10
	li r2, u_ro - ROM_BASE + USER_VA
	li r3, VA_T + 0x2000
	call check_log
	li r28, 13                  ; devices
	li r1, 9
	li r2, u_io - ROM_BASE + USER_VA
	li r3, UART + UART_STATUS
	call check_log
	li r28, 14                  ; the one-to-one ROM mapping
	li r1, 9
	li r2, u_rom - ROM_BASE + USER_VA
	la r3, rom_word
	call check_log
	li r28, 15
	li r1, 8
	la r2, rom_code
	la r3, rom_code
	call check_log
	li r28, 16
	li r1, CAUSE_SYSCALL
	li r2, u_exit - ROM_BASE + USER_VA
	li r3, 0
	call check_log
	li r28, 17                  ; nothing else
	lw r4, LOG_PTR(r0)
	bne r4, r10, fail
	j pass

; check_log(r1 = CAUSE, r2 = EPC, r3 = BADADDR): the next log entry matches
; and was raised in user mode; r4 = the mismatching value
check_log:
	lw r4, 0(r10)
	bne r4, r1, fail
	lw r4, 4(r10)
	bne r4, r2, fail
	lw r4, 8(r10)
	bne r4, r3, fail
	lw r4, 12(r10)
	li r3, STATUS_PUM | STATUS_EXL
	bne r4, r3, fail
	addi r10, r10, 16
	ret

; ---- the handler (r20-r27) ----------------------------------------------------

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
	li r27, 8
	bne r20, r27, .not_fetch
	mv r26, r31                 ; a fetch fault: back to the caller
.not_fetch:
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

; ---- user code: no absolute addresses of its own labels ------------------

user_prog:
	li r10, VA_T
	li r6, 0x66
	lw r5, 0(r10)               ; a U page: fine
	addi r1, r5, 1
	sw r1, 4(r10)
	li r12, VA_T + 0x2000
	lw r7, 0(r12)               ; read-only U page: loads are fine
	mfcr r8, cycle
u_super:
	lw r6, 0x1000(r10)          ; no U
u_super_st:
	sw r6, 0x1004(r10)
u_ro:
	sw r0, 0(r12)               ; no W
	li r11, UART
u_io:
	lw r6, UART_STATUS(r11)
	la r11, rom_word
u_rom:
	lw r6, 0(r11)
	la r11, rom_code
	jalr ra, r11                ; fetch without U: back here
	li r1, SYS_EXIT
u_exit:
	syscall
	j fail

rom_word:
	.dw 0x12345678
rom_code:
	j fail
