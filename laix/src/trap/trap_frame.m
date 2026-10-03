import { GPR_COUNT, WORD_BYTES } from "../arch/wrm081632/defs.m"
let TF_REGS: UWord = 0
let TF_EPC: UWord = GPR_COUNT * WORD_BYTES
let TF_STATUS: UWord = TF_EPC + WORD_BYTES
let TF_CAUSE: UWord = TF_STATUS + WORD_BYTES
let TF_BADADDR: UWord = TF_CAUSE + WORD_BYTES
let TF_FCSR: UWord = TF_BADADDR + WORD_BYTES
let TF_PTBR: UWord = TF_FCSR + WORD_BYTES
let TF_RESERVED: UWord = TF_PTBR + WORD_BYTES
let TF_RESERVED_WORDS: UWord = 2
let TF_SIZE: UWord = TF_RESERVED + TF_RESERVED_WORDS * WORD_BYTES
// Shared ABI with trap_layout.inc: regs[n] is the interrupted rn.
// status is captured AFTER hardware entry; PUM/PIE/PSS describe the origin.
type TrapFrame {
    regs: UWord[GPR_COUNT],
    epc: UWord,
    status: UWord,
    cause: UWord,
    badaddr: UWord,
    fcsr: UWord,
    ptbr: UWord,
    reserved: UWord[TF_RESERVED_WORDS],
}

let trapLayoutValid(): Bool {
    return sizeof(TrapFrame) == TF_SIZE &&
        offsetof(TrapFrame, regs) == TF_REGS &&
        offsetof(TrapFrame, epc) == TF_EPC &&
        offsetof(TrapFrame, status) == TF_STATUS &&
        offsetof(TrapFrame, cause) == TF_CAUSE &&
        offsetof(TrapFrame, badaddr) == TF_BADADDR &&
        offsetof(TrapFrame, fcsr) == TF_FCSR &&
        offsetof(TrapFrame, ptbr) == TF_PTBR &&
        offsetof(TrapFrame, reserved) == TF_RESERVED
}

export { TrapFrame, trapLayoutValid }
