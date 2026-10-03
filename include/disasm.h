#ifndef WRM_DISASM_H
#define WRM_DISASM_H
#include "common.h"

// Enough for the longest instruction text, with the terminating zero
#define DISASM_MAX_LENGTH 40

// Writes the instruction raw, located at pc, in the syntax of mc/asm.py,
// so the text assembles back to the same word: branch and JAL targets are
// absolute addresses, and a word the assembler can't produce (unknown
// opcode, reserved bits set, ...) becomes ".word 0x...".
// mc/disasm.py does the same for images.
void disasm_instruction(const uint32_t raw, const uint32_t pc, char* out,
						const size_t size);

// Assembler name of a control register ("status"), NULL if there is none.
const char* disasm_cr_name(const uint32_t cr);

#endif // WRM_DISASM_H
