// Shared ABI with trap_layout.inc: regs[n] is the interrupted rn.
// status is captured AFTER hardware entry; PUM/PIE/PSS describe the origin.
type TrapFrame {
    regs: UWord[32],
    epc: UWord,
    status: UWord,
    cause: UWord,
    badaddr: UWord,
    fcsr: UWord,
    ptbr: UWord,
    reserved: UWord[2],
}

let trapLayoutValid(): Bool {
    return sizeof(TrapFrame) == 160 &&
        offsetof(TrapFrame, regs) == 0 &&
        offsetof(TrapFrame, epc) == 128 &&
        offsetof(TrapFrame, status) == 132 &&
        offsetof(TrapFrame, cause) == 136 &&
        offsetof(TrapFrame, badaddr) == 140 &&
        offsetof(TrapFrame, fcsr) == 144 &&
        offsetof(TrapFrame, ptbr) == 148 &&
        offsetof(TrapFrame, reserved) == 152
}

export { TrapFrame, trapLayoutValid }
