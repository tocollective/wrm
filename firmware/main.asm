; ============================================================================
;  WRM.081632 demo firmware
;
;  A tour of the machine: every instruction group, the UART, the keyboard,
;  the PIC, polling, WFI and interrupts, plus most assembler features
;  (constants, local labels, expressions, pseudo-instructions, directives).
;  All output goes to the UART, i.e. to the host's stdout.
;
;  Build:  python3 tools/asm.py firmware/main.asm -o firmware.rom
;
;  Register conventions of this program (the hardware only fixes r0 = 0):
;    r1-r4     arguments, r1 = return value
;    r1-r9     scratch, clobbered by every call
;    r10-r29   preserved across calls
;    r30       stack pointer, grows down, word aligned
;    r31 (ra)  return address, written by JAL/CALL, used by RET
; ============================================================================

; ---- memory map (docs/SPECIFICATION.md) ------------------------------------

ROM_BASE        = 0xFE000000
PIC             = 0xFD000000
KBD             = 0xFD001000
UART            = 0xFD002000

PIC_PENDING     = 0x00
PIC_ENABLE      = 0x04
PIC_ACTIVE      = 0x08
PIC_CLAIM       = 0x0C
IRQ_KBD         = 0
IRQ_UART        = 1

KBD_STATUS      = 0x00
KBD_DATA        = 0x04
KBD_CONTROL     = 0x08
KBD_READY       = 1 << 0
KBD_OVERFLOW    = 1 << 1
KBD_FLUSH       = 1 << 0

UART_DATA       = 0x00
UART_STATUS     = 0x04
UART_CONTROL    = 0x08
UART_TX_READY   = 1 << 1
UART_FLUSH      = 1 << 0

STATUS_IE       = 1 << 0

; USB HID usage IDs (page 0x07)
HID_A           = 0x04
HID_ESCAPE      = 0x29

; ---- RAM layout (slot 0, at least 1MB) --------------------------------------
; Variables sit below 8KB, so they are reached as offset(r0) with no base
; register at all.

VAR_IRQ_COUNT   = 0x0100
VAR_KEY_COUNT   = 0x0104
VAR_QUIT        = 0x0108
BUFFER          = 0x0200
IRQ_STACK_TOP   = 0x00080000
STACK_TOP       = 0x00100000

NAME_WIDTH      = 24            ; column where show() prints values

; ============================================================================
;  Reset
; ============================================================================

	.org ROM_BASE               ; pc = 0xFE000000 after reset
reset:
	nop
	li r30, STACK_TOP           ; low 13 bits are zero: a single LUI
	sw r0, VAR_IRQ_COUNT(r0)
	sw r0, VAR_KEY_COUNT(r0)
	sw r0, VAR_QUIT(r0)
	li r1, UART
	li r2, UART_FLUSH
	sw r2, UART_CONTROL(r1)     ; drop anything received before reset

	la r1, s_banner
	call puts
	la r1, rom_size
	lw r2, 0(r1)
	la r1, s_rom_size
	call show

	call demo_alu
	call demo_memory
	call demo_calls
	call demo_pcrel
	call demo_polling
	call demo_interrupts

	la r1, s_bye
	call puts
	hlt

; ============================================================================
;  [1] Arithmetic and logic
; ============================================================================

demo_alu:
	addi r30, r30, -20
	sw ra, 16(r30)
	sw r10, 12(r30)
	sw r11, 8(r30)
	sw r12, 4(r30)
	sw r13, 0(r30)

	la r1, s_alu_title
	call puts

	li r10, 1000                ; a
	li r11, -7                  ; b
	li r12, 0x0FF0              ; m
	li r13, 4                   ; s

	; register forms
	la r1, s_add
	add r2, r10, r11
	call show
	la r1, s_sub
	sub r2, r10, r11
	call show
	la r1, s_mul
	mul r2, r10, r11
	call show
	la r1, s_div
	div r2, r10, r11
	call show
	la r1, s_rem
	rem r2, r10, r11
	call show
	la r1, s_divu
	divu r2, r10, r11
	call show
	la r1, s_remu
	remu r2, r10, r11
	call show
	la r1, s_slt
	slt r2, r11, r10
	call show
	la r1, s_sltu
	sltu r2, r11, r10
	call show
	la r1, s_and
	and r2, r10, r12
	call show
	la r1, s_or
	or r2, r10, r12
	call show
	la r1, s_xor
	xor r2, r10, r12
	call show
	la r1, s_shl
	shl r2, r11, r13
	call show
	la r1, s_shr
	shr r2, r11, r13
	call show
	la r1, s_sar
	sar r2, r11, r13
	call show

	; immediate forms
	la r1, s_addi
	addi r2, r10, -1
	call show
	la r1, s_andi
	andi r2, r10, 0xF
	call show
	la r1, s_ori
	ori r2, r10, 0x3000
	call show
	la r1, s_xori
	xori r2, r10, 0x3FFF
	call show
	la r1, s_shli
	shli r2, r10, 20
	call show
	la r1, s_shri
	shri r2, r11, 28
	call show
	la r1, s_sari
	sari r2, r11, 1
	call show
	la r1, s_slti
	slti r2, r11, 0
	call show
	la r1, s_sltiu
	sltiu r2, r11, 1
	call show

	; upper immediates and 32-bit constants
	la r1, s_lui
	lui r2, 0x7FFFF
	call show
	la r1, s_li
	li r2, 0xDEADBEEF           ; LUI %hi + ORI %lo
	call show

	; corner cases: division never traps
	la r1, s_div0
	div r2, r10, r0
	call show
	la r1, s_rem0
	rem r2, r10, r0
	call show
	la r1, s_div_ovf
	li r2, 0x80000000
	li r3, -1
	div r2, r2, r3
	call show

	lw r13, 0(r30)
	lw r12, 4(r30)
	lw r11, 8(r30)
	lw r10, 12(r30)
	lw ra, 16(r30)
	addi r30, r30, 20
	ret

; ============================================================================
;  [2] Loads and stores
; ============================================================================

demo_memory:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r10, 0(r30)

	la r1, s_mem_title
	call puts

	; copy the table from ROM to RAM, print it, sort it, print it again
	li r1, BUFFER
	la r2, numbers
	li r3, numbers_end - numbers
	call memcpy
	la r1, s_ram_copy
	call puts
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call print_array
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call sort
	la r1, s_sorted
	call puts
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call print_array

	; sum it (32-bit wrap-around)
	li r3, BUFFER
	li r4, BUFFER + NUMBER_COUNT * 4
	li r2, 0
.sum:
	lw r5, 0(r3)                ; load-use: the pipeline stalls 1 cycle, invisibly
	add r2, r2, r5
	addi r3, r3, 4
	bltu r3, r4, .sum
	la r1, s_sum
	call show

	; sign and zero extension
	la r10, sign_demo
	la r1, s_lb
	lb r2, 0(r10)
	call show
	la r1, s_lbu
	lbu r2, 0(r10)
	call show
	la r1, s_lh
	lh r2, 2(r10)
	call show
	la r1, s_lhu
	lhu r2, 2(r10)
	call show

	; the machine is little-endian
	li r10, BUFFER + 0x100
	li r2, 0x11
	sb r2, 0(r10)
	li r2, 0x22
	sb r2, 1(r10)
	li r2, 0x33
	sb r2, 2(r10)
	li r2, 0x44
	sb r2, 3(r10)
	la r1, s_sb_lw
	lw r2, 0(r10)
	call show
	li r2, 0xBEEF
	sh r2, 0(r10)
	la r1, s_sh_lw
	lw r2, 0(r10)
	call show

	lw r10, 0(r30)
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; ============================================================================
;  [3] Calls, recursion, loops, jump tables
; ============================================================================

demo_calls:
	addi r30, r30, -20
	sw ra, 16(r30)
	sw r10, 12(r30)
	sw r11, 8(r30)
	sw r12, 4(r30)
	sw r13, 0(r30)

	la r1, s_calls_title
	call puts

	li r1, 10
	jal ra, factorial           ; the long form of CALL
	mv r2, r1
	la r1, s_fact
	call show

	li r1, 1071
	li r2, 462
	call gcd
	mv r2, r1
	la r1, s_gcd
	call show

	; call every function in op_table with (25, -40)
	li r10, 0                   ; index
.next_op:
	shli r11, r10, 2            ; byte offset into the tables
	la r1, op_table
	add r1, r1, r11
	lw r12, 0(r1)               ; function pointer
	la r1, op_names
	add r1, r1, r11
	lw r13, 0(r1)               ; its name
	li r1, 25
	li r2, -40
	jalr ra, r12, 0             ; indirect call
	mv r2, r1
	mv r1, r13
	call show
	addi r10, r10, 1
	slti r1, r10, OP_COUNT
	bnez r1, .next_op

	lw r13, 0(r30)
	lw r12, 4(r30)
	lw r11, 8(r30)
	lw r10, 12(r30)
	lw ra, 16(r30)
	addi r30, r30, 20
	ret

; factorial(r1 = n) -> r1 = n!, recursive to exercise the stack
factorial:
	slti r2, r1, 2
	beqz r2, .recurse
	li r1, 1
	ret
.recurse:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	addi r1, r1, -1
	call factorial
	lw r2, 0(r30)
	mul r1, r1, r2
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; gcd(r1, r2) -> r1, Euclid's algorithm
gcd:
	beqz r2, .done
	remu r3, r1, r2
	mv r1, r2
	mv r2, r3
	j gcd
.done:
	ret

; op_*(r1, r2) -> r1, called through op_table
op_add:
	add r1, r1, r2
	ret
op_sub:
	sub r1, r1, r2
	ret
op_max:
	bge r1, r2, .keep
	mv r1, r2
.keep:
	ret
op_min:
	ble r1, r2, .keep
	mv r1, r2
.keep:
	ret
op_mulh:                        ; (r1 * r2) >> 16, arithmetic
	mul r1, r1, r2
	sari r1, r1, 16
	ret

; ============================================================================
;  [4] PC-relative code
; ============================================================================

demo_pcrel:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_pcrel_title
	call puts

.here:
	auipc r2, 0                 ; r2 = address of this very instruction
	la r1, s_auipc
	call show
	la r1, s_la_here
	la r2, .here                ; the same address, known to the assembler
	call show
	la r1, s_la_dollar
	la r2, $                    ; $ = address of the current line
	call show

	; AUIPC + JALR reach any address, JAL only +-1MB
.far:
	auipc r5, %hi(far_target - .far)
	jalr ra, r5, %lo(far_target - .far)

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

far_target:
	la r1, s_far
	j puts                      ; tail call: puts returns to demo_pcrel

; ============================================================================
;  [5] Polling: PIC line enabled, IE = 0
; ============================================================================

demo_polling:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_poll_title
	call puts

	li r9, KBD
	li r2, KBD_FLUSH
	sw r2, KBD_CONTROL(r9)
	li r9, PIC
	li r2, 1 << IRQ_KBD
	sw r2, PIC_ENABLE(r9)       ; the line drives the CPU IRQ input...
.wait:
	wfi                         ; ...but with IE = 0 WFI just wakes up and continues
	li r9, KBD
	lw r2, KBD_STATUS(r9)
	andi r2, r2, KBD_READY
	beqz r2, .wait

	li r9, PIC
	la r1, s_pic_pending
	lw r2, PIC_PENDING(r9)
	call show
	li r9, PIC
	la r1, s_pic_claim
	lw r2, PIC_CLAIM(r9)
	call show
	li r9, KBD
	la r1, s_kbd_event
	lw r2, KBD_DATA(r9)         ; pops the event
	call show

	li r9, PIC
	sw r0, PIC_ENABLE(r9)

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; ============================================================================
;  [6] Interrupts
; ============================================================================

demo_interrupts:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_irq_title
	call puts

	la r1, irq_handler
	mtcr ivec, r1

	li r2, KBD_FLUSH
	li r9, KBD
	sw r2, KBD_CONTROL(r9)
	li r2, UART_FLUSH
	li r9, UART
	sw r2, UART_CONTROL(r9)

	li r9, PIC
	li r2, (1 << IRQ_KBD) | (1 << IRQ_UART)
	sw r2, PIC_ENABLE(r9)
	li r2, STATUS_IE
	mtcr status, r2
	la r1, s_status
	mfcr r2, status
	call show

.idle:
	wfi                         ; sleep; the handler runs and IRETs back here
	lw r2, VAR_QUIT(r0)
	beqz r2, .idle

	mtcr status, r0             ; no interrupts after this instruction
	li r9, PIC
	sw r0, PIC_ENABLE(r9)

	la r1, s_irq_count
	lw r2, VAR_IRQ_COUNT(r0)
	call show
	la r1, s_key_count
	lw r2, VAR_KEY_COUNT(r0)
	call show

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; The CPU jumps here with IE = 0 and EPC = the interrupted instruction.
; Everything the handler touches is restored before IRET.
irq_handler:
	mtcr scratch, r30           ; stash the interrupted stack pointer
	li r30, IRQ_STACK_TOP       ; and switch to the interrupt stack
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

	lw r1, VAR_IRQ_COUNT(r0)
	addi r1, r1, 1
	sw r1, VAR_IRQ_COUNT(r0)

.claim:
	li r1, PIC
	lw r1, PIC_CLAIM(r1)        ; lowest active line
	bltz r1, .done              ; 0xFFFFFFFF: nothing left
	li r2, IRQ_KBD
	beq r1, r2, .kbd
	li r2, IRQ_UART
	beq r1, r2, .uart
	j .done
.kbd:
	call on_key
	j .claim
.uart:
	call on_uart
	j .claim

.done:
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
	iret                        ; pc = EPC, IE = PIE

; Pops one keyboard event and describes it; Esc asks the main loop to quit.
on_key:
	addi r30, r30, -12
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)

	li r9, KBD
	lw r2, KBD_STATUS(r9)       ; reading STATUS also clears the overflow bit
	andi r2, r2, KBD_OVERFLOW
	beqz r2, .no_overflow
	la r1, s_overflow
	call puts
.no_overflow:
	li r9, KBD
	lw r10, KBD_DATA(r9)        ; the line drops once the FIFO is empty
	shli r11, r10, 16
	shri r11, r11, 16           ; usage ID; ANDI can't take 0xFFFF (14 bits)

	la r1, s_key
	call puts
	mv r1, r11
	li r2, 4
	call print_hex
	bltz r10, .released         ; bit 31 = released

	lw r1, VAR_KEY_COUNT(r0)
	addi r1, r1, 1
	sw r1, VAR_KEY_COUNT(r0)
	la r1, s_pressed
	call puts

	addi r10, r11, -HID_A       ; letters a-z are usage IDs 0x04-0x1D
	sltiu r1, r10, 26
	beqz r1, .not_letter
	li r1, ' '
	call putc
	addi r1, r10, 'a'
	call putc
.not_letter:
	addi r1, r11, -HID_ESCAPE
	bnez r1, .newline
	li r1, 1
	sw r1, VAR_QUIT(r0)
	la r1, s_esc
	call puts
	j .newline
.released:
	la r1, s_released
	call puts
.newline:
	li r1, '\n'
	call putc

	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 12
	ret

; Echoes one received byte back.
on_uart:
	li r9, UART
	lw r1, UART_DATA(r9)        ; the line drops once the RX FIFO is empty
	j putc

; ============================================================================
;  Library
; ============================================================================

; putc(r1 = byte)
putc:
	li r9, UART
.wait:
	lw r8, UART_STATUS(r9)
	andi r8, r8, UART_TX_READY  ; always set here, polled for good form
	beqz r8, .wait
	sw r1, UART_DATA(r9)
	ret

; puts(r1 = zero-terminated string) -> r1 = address of the terminator
puts:
	li r9, UART
.next:
	lbu r2, 0(r1)
	beqz r2, .done
	sw r2, UART_DATA(r9)
	addi r1, r1, 1
	j .next
.done:
	ret

; pad(r1 = count): prints count spaces, nothing if count <= 0
pad:
	li r9, UART
	li r2, ' '
.next:
	blez r1, .done
	sw r2, UART_DATA(r9)
	addi r1, r1, -1
	j .next
.done:
	ret

; print_hex(r1 = value, r2 = digits)
print_hex:
	li r9, UART
	la r3, hex_digits
	addi r4, r2, -1
	shli r4, r4, 2              ; shift of the top digit
.next:
	shr r5, r1, r4
	andi r5, r5, 0xF
	add r5, r3, r5
	lbu r5, 0(r5)
	sw r5, UART_DATA(r9)
	addi r4, r4, -4
	bgez r4, .next
	ret

; print_dec(r1 = unsigned value)
print_dec:
	addi r30, r30, -16
	sw ra, 12(r30)
	addi r3, r30, 11            ; digits go backwards into 1..10(r30)
	sb r0, 0(r3)
	li r4, 10
.next:
	remu r2, r1, r4
	addi r2, r2, '0'
	addi r3, r3, -1
	sb r2, 0(r3)
	divu r1, r1, r4
	bnez r1, .next
	mv r1, r3
	call puts
	lw ra, 12(r30)
	addi r30, r30, 16
	ret

; print_int(r1 = signed value)
print_int:
	bgez r1, print_dec          ; tail call for non-negative values
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	li r1, '-'
	call putc
	lw r1, 0(r30)
	neg r1, r1                  ; 0x80000000 stays as is and prints unsigned
	call print_dec
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; show(r1 = name, r2 = value): "name      = value (0xVALUE)\n"
show:
	addi r30, r30, -12
	sw ra, 8(r30)
	sw r2, 4(r30)
	sw r1, 0(r30)
	call puts                   ; r1 = end of the name
	lw r2, 0(r30)
	sub r1, r1, r2              ; name length
	neg r1, r1
	addi r1, r1, NAME_WIDTH
	call pad
	la r1, s_equals
	call puts
	lw r1, 4(r30)
	call print_int
	la r1, s_hex_open
	call puts
	lw r1, 4(r30)
	li r2, 8
	call print_hex
	la r1, s_hex_close
	call puts
	lw ra, 8(r30)
	addi r30, r30, 12
	ret

; print_array(r1 = words, r2 = count): signed values on one line
print_array:
	addi r30, r30, -12
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)
	mv r10, r1
	mv r11, r2
.next:
	beqz r11, .done
	lw r1, 0(r10)
	call print_int
	li r1, ' '
	call putc
	addi r10, r10, 4
	addi r11, r11, -1
	j .next
.done:
	li r1, '\n'
	call putc
	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 12
	ret

; memcpy(r1 = dst, r2 = src, r3 = bytes), word-aligned, whole words
memcpy:
	add r3, r2, r3              ; end of the source
	bgeu r2, r3, .done
.next:
	lw r4, 0(r2)
	sw r4, 0(r1)
	addi r2, r2, 4
	addi r1, r1, 4
	bltu r2, r3, .next
.done:
	ret

; sort(r1 = words, r2 = count): bubble sort, signed, ascending
sort:
	addi r2, r2, -1             ; passes left
.pass:
	blez r2, .done
	mv r3, r1                   ; current pair
	mv r4, r2                   ; compares in this pass
.step:
	lw r5, 0(r3)
	lw r6, 4(r3)
	ble r5, r6, .ordered
	sw r6, 0(r3)
	sw r5, 4(r3)
.ordered:
	addi r3, r3, 4
	addi r4, r4, -1
	bnez r4, .step
	addi r2, r2, -1
	j .pass
.done:
	ret

; ============================================================================
;  Read-only data
; ============================================================================

hex_digits:     .ascii "0123456789ABCDEF"

	.align 4
numbers:        .word 42, -17, 1000000, 0, -2147483648, 7, 0x7FFFFFFF, -1
numbers_end:
NUMBER_COUNT = (numbers_end - numbers) / 4

sign_demo:      .byte 0x80, 0x7F
	.half 0x8001                ; offset 2: naturally aligned

	.align 4
op_table:       .word op_add, op_sub, op_max, op_min, op_mulh
op_table_end:
op_names:       .word s_op_add, s_op_sub, s_op_max, s_op_min, s_op_mulh
OP_COUNT = (op_table_end - op_table) / 4

s_banner:
	.ascii "\n"
	.ascii "WRM.081632 demo firmware\n"
	.asciz "========================\n"
s_rom_size:     .asciz "firmware size, bytes"

s_alu_title:    .asciz "\n[1] ALU: a = 1000, b = -7, m = 0x0FF0, s = 4\n"
s_add:          .asciz "ADD   a + b"
s_sub:          .asciz "SUB   a - b"
s_mul:          .asciz "MUL   a * b"
s_div:          .asciz "DIV   a / b"
s_rem:          .asciz "REM   a % b"
s_divu:         .asciz "DIVU  a / b"
s_remu:         .asciz "REMU  a % b"
s_slt:          .asciz "SLT   b < a"
s_sltu:         .asciz "SLTU  b < a"
s_and:          .asciz "AND   a & m"
s_or:           .asciz "OR    a | m"
s_xor:          .asciz "XOR   a ^ m"
s_shl:          .asciz "SHL   b << s"
s_shr:          .asciz "SHR   b >> s"
s_sar:          .asciz "SAR   b >> s"
s_addi:         .asciz "ADDI  a + -1"
s_andi:         .asciz "ANDI  a & 0xF"
s_ori:          .asciz "ORI   a | 0x3000"
s_xori:         .asciz "XORI  a ^ 0x3FFF"
s_shli:         .asciz "SHLI  a << 20"
s_shri:         .asciz "SHRI  b >> 28"
s_sari:         .asciz "SARI  b >> 1"
s_slti:         .asciz "SLTI  b < 0"
s_sltiu:        .asciz "SLTIU b < 1"
s_lui:          .asciz "LUI   0x7FFFF"
s_li:           .asciz "LI    0xDEADBEEF"
s_div0:         .asciz "DIV   a / 0"
s_rem0:         .asciz "REM   a % 0"
s_div_ovf:      .asciz "DIV   INT_MIN / -1"

s_mem_title:    .asciz "\n[2] memory\n"
s_ram_copy:     .asciz "copied to RAM: "
s_sorted:       .asciz "sorted:        "
s_sum:          .asciz "sum"
s_lb:           .asciz "LB    0x80"
s_lbu:          .asciz "LBU   0x80"
s_lh:           .asciz "LH    0x8001"
s_lhu:          .asciz "LHU   0x8001"
s_sb_lw:        .asciz "SB 11 22 33 44, LW"
s_sh_lw:        .asciz "SH 0xBEEF, LW"

s_calls_title:  .asciz "\n[3] calls\n"
s_fact:         .asciz "factorial(10)"
s_gcd:          .asciz "gcd(1071, 462)"
s_op_add:       .asciz "op_add(25, -40)"
s_op_sub:       .asciz "op_sub(25, -40)"
s_op_max:       .asciz "op_max(25, -40)"
s_op_min:       .asciz "op_min(25, -40)"
s_op_mulh:      .asciz "op_mulh(25, -40)"

s_pcrel_title:  .asciz "\n[4] pc-relative\n"
s_auipc:        .asciz "AUIPC r2, 0"
s_la_here:      .asciz "LA r2, .here"
s_la_dollar:    .asciz "LA r2, $"
s_far:          .asciz "far_target reached through AUIPC + JALR\n"

s_poll_title:   .asciz "\n[5] polling: press any key in the WRM window\n"
s_pic_pending:  .asciz "PIC PENDING"
s_pic_claim:    .asciz "PIC CLAIM"
s_kbd_event:    .asciz "keyboard event"

s_irq_title:    .asciz "\n[6] interrupts: press keys in the window (Esc quits)\n    or type in the terminal (echoed through the UART)\n"
s_status:       .asciz "STATUS"
s_key:          .asciz "key 0x"
s_pressed:      .asciz " pressed"
s_released:     .asciz " released"
s_esc:          .asciz " (Esc)"
s_overflow:     .asciz "keyboard FIFO overflowed, events were lost\n"
s_irq_count:    .asciz "interrupts taken"
s_key_count:    .asciz "keys pressed"

s_equals:       .asciz "= "
s_hex_open:     .asciz " (0x"
s_hex_close:    .asciz ")\n"
s_bye:          .asciz "\nbye\n"

; image trailer: a small header-like block built from data directives
	.align 16
rom_info:
	.string "WRM"               ; magic, NUL-terminated
	.dh 1, 0                    ; version 1.0
	.db 'D', 'E', 'M', 'O'
	.space 4, 0xFF              ; reserved
rom_size:
	.dw rom_end - ROM_BASE      ; image size, including this word
rom_end:
