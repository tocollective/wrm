// [4] PC-relative code: AUIPC has no M form, so the demo is assembly
// (pcrel.asm). It calls show() from lib.m like any M function would.

extern let demoPcrel(): Void

export { demoPcrel }
