; ============================================================================
;  Boot from the floppy or disk 0 (docs/SPECIFICATION.md#boot-protocol)
; ============================================================================

; boot(): loads the boot image from the first drive that holds one, the
; floppy and then disk 0, and jumps to it. Returns only if there is
; nothing to boot: no disks (silently), no boot image or an error (after
; printing why, for each drive). Runs on its own stack below BOOT_LOAD,
; so the image can't overwrite it wherever the caller's stack is.
boot:
	mv r9, r30
	li r30, BOOT_STACK_TOP
	addi r30, r30, -24
	sw r9, 20(r30)              ; the caller's stack
	sw ra, 16(r30)
	sw r10, 12(r30)
	sw r11, 8(r30)
	sw r12, 4(r30)
	sw r13, 0(r30)

	li r10, FLOPPY
	la r13, s_boot_floppy
	call boot_disk
	li r10, DISK0
	la r13, s_boot_disk0
	call boot_disk

	lw r13, 0(r30)
	lw r12, 4(r30)
	lw r11, 8(r30)
	lw r10, 12(r30)
	lw ra, 16(r30)
	lw r30, 20(r30)
	ret

; boot_disk(r10 = disk controller, r13 = its name for messages): boots
; from that disk, or returns if it can't. Clobbers r11 and r12 too, which
; boot saves.
boot_disk:
	addi r30, r30, -4
	sw ra, 0(r30)

	lw r1, DISK_STATUS(r10)
	andi r1, r1, DISK_PRESENT
	beqz r1, .return

	; sector 0 starts with the header
	mv r1, r10
	li r2, DISK_READ
	li r3, 0
	li r4, 1
	li r5, BOOT_LOAD
	call disk_io
	bnez r1, .disk_error
	li r9, BOOT_LOAD
	la r3, s_boot_no_image
	lw r1, BOOT_HDR_MAGIC(r9)
	li r2, BOOT_MAGIC
	bne r1, r2, .fail

	la r3, s_boot_bad_header
	lw r1, BOOT_HDR_FLAGS(r9)
	bnez r1, .fail
	lw r11, BOOT_HDR_SECTORS(r9)
	beqz r11, .fail
	lw r1, DISK_SECTORS(r10)
	bgtu r11, r1, .fail         ; runs past the end of the disk
	call ram_size
	mv r12, r1
	la r3, s_boot_too_big
	li r2, BOOT_LOAD
	sub r1, r1, r2
	shri r1, r1, 9              ; sectors that fit above BOOT_LOAD
	bgtu r11, r1, .fail
	la r3, s_boot_bad_header
	li r9, BOOT_LOAD
	lw r1, BOOT_HDR_ENTRY(r9)
	andi r2, r1, 3
	bnez r2, .fail
	shli r2, r11, 9             ; image size
	bgeu r1, r2, .fail          ; the entry must be inside the image

	; the rest of the image right after sector 0
	mv r1, r10
	li r2, DISK_READ
	li r3, 1
	addi r4, r11, -1
	li r5, BOOT_LOAD + SECTOR_SIZE
	call disk_io
	bnez r1, .disk_error

	li r9, BOOT_INFO
	li r1, BOOT_INFO_MAGIC
	sw r1, BI_MAGIC(r9)
	li r1, BOOT_INFO_SIZE
	sw r1, BI_SIZE(r9)
	sw r12, BI_RAM_SIZE(r9)
	sw r10, BI_DISK(r9)
	lw r1, DISK_SECTORS(r10)
	sw r1, BI_DISK_SECTORS(r9)
	li r1, BOOT_LOAD
	sw r1, BI_IMAGE(r9)
	shli r1, r11, 9
	sw r1, BI_IMAGE_SIZE(r9)
	li r1, TIMER
	lw r1, TIMER_FREQUENCY(r1)
	sw r1, BI_CLOCK(r9)

	; the state after reset, except for what the protocol passes on
	li r1, PIC
	sw r0, PIC_ENABLE(r1)
	mtcr ptbr, r0
	mtcr ivec, r0
	li r1, STATUS_EXL
	mtcr status, r1
	li r9, BOOT_LOAD
	lw r2, BOOT_HDR_ENTRY(r9)
	add r9, r9, r2
	li r1, BOOT_INFO
	li r2, 0
	li r30, BOOT_STACK_TOP
	li ra, 0
	jr r9

.disk_error:                    ; r1 = ERROR
	mv r11, r1
	la r3, s_boot_disk_error
	call .message
	mv r1, r11
	call print_dec
	li r1, '\n'
	call putc
	j .return
.fail:                          ; r3 = message
	call .message
.return:
	lw ra, 0(r30)
	addi r30, r30, 4
	ret
.message:                       ; "boot: <drive>" and r3; keeps r11
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r3, 0(r30)
	la r1, s_boot
	call puts
	mv r1, r13
	call puts
	lw r1, 0(r30)
	call puts
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; ram_size() -> r1 = bytes of RAM from address 0
; Slots are 1MB-32MB each and laid out back to back, so RAM ends at a 1MB
; boundary: loads from each boundary until one is a bus error. Borrows
; IVEC and runs with STATUS = 0 meanwhile, then restores both.
ram_size:
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

s_boot:            .asciz "boot: "
s_boot_floppy:     .asciz "floppy"
s_boot_disk0:      .asciz "disk 0"
s_boot_disk_error: .asciz ": disk error "
s_boot_no_image:   .asciz ": no boot image\n"
s_boot_bad_header: .asciz ": bad boot image header\n"
s_boot_too_big:    .asciz ": the boot image doesn't fit in RAM\n"

	.align 4
