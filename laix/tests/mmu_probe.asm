; Assembly companion of mmu_probe.m. r1 is the virtual address from M.
; Exact fault PCs are
; global symbols so run_ready checks the hardware EPC against the map.
    .text
    .globl triggerMmuLoad, mmuLoadInstruction, triggerMmuStore, mmuStoreInstruction
triggerMmuLoad:
mmuLoadInstruction:
    lw r2, 0(r1)
    ret
triggerMmuStore:
mmuStoreInstruction:
    sw r0, 0(r1)
    ret
