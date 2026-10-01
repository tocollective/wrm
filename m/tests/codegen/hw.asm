; A system call handler for hw.m: there is no kernel, so this one answers
; r1 = a1 + a2 + a3 + a4 + a5 + a6 + 100 * n and resumes after SYSCALL
; (docs/ABI.md, "System calls"). It keeps every register but r1 and r2.

syscallHandler:
	add r1, r1, r2
	add r1, r1, r3
	add r1, r1, r4
	add r1, r1, r5
	add r1, r1, r6
	li r2, 100
	mul r2, r9, r2
	add r1, r1, r2
	mfcr r2, epc
	addi r2, r2, 4
	mtcr epc, r2
	iret
