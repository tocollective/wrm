#include "disasm.h"

#include <stdio.h>

#include "cpu.h"

static const char* const disasm_mnemonics[256] = {
	[CPU_OP_HLT] = "hlt",     [CPU_OP_NOP] = "nop",     [CPU_OP_WFI] = "wfi",
	[CPU_OP_IRET] = "iret",   [CPU_OP_MFCR] = "mfcr",   [CPU_OP_MTCR] = "mtcr",
	[CPU_OP_TLBI] = "tlbi",   [CPU_OP_SYSCALL] = "syscall",
	[CPU_OP_FENCE] = "fence", [CPU_OP_BREAK] = "break",

	[CPU_OP_ADD] = "add",     [CPU_OP_SUB] = "sub",     [CPU_OP_AND] = "and",
	[CPU_OP_OR] = "or",       [CPU_OP_XOR] = "xor",     [CPU_OP_SHL] = "shl",
	[CPU_OP_SHR] = "shr",     [CPU_OP_SAR] = "sar",     [CPU_OP_SLT] = "slt",
	[CPU_OP_SLTU] = "sltu",   [CPU_OP_MUL] = "mul",     [CPU_OP_DIV] = "div",
	[CPU_OP_DIVU] = "divu",   [CPU_OP_REM] = "rem",     [CPU_OP_REMU] = "remu",
	[CPU_OP_MULH] = "mulh",   [CPU_OP_MULHU] = "mulhu",
	[CPU_OP_MULHSU] = "mulhsu",

	[CPU_OP_ADDI] = "addi",   [CPU_OP_ANDI] = "andi",   [CPU_OP_ORI] = "ori",
	[CPU_OP_XORI] = "xori",   [CPU_OP_SHLI] = "shli",   [CPU_OP_SHRI] = "shri",
	[CPU_OP_SARI] = "sari",   [CPU_OP_SLTI] = "slti",   [CPU_OP_SLTIU] = "sltiu",

	[CPU_OP_LUI] = "lui",     [CPU_OP_AUIPC] = "auipc",

	[CPU_OP_LB] = "lb",       [CPU_OP_LBU] = "lbu",     [CPU_OP_LH] = "lh",
	[CPU_OP_LHU] = "lhu",     [CPU_OP_LW] = "lw",       [CPU_OP_SB] = "sb",
	[CPU_OP_SH] = "sh",       [CPU_OP_SW] = "sw",
	[CPU_OP_LL] = "ll",       [CPU_OP_SC] = "sc",

	[CPU_OP_BEQ] = "beq",     [CPU_OP_BNE] = "bne",     [CPU_OP_BLT] = "blt",
	[CPU_OP_BGE] = "bge",     [CPU_OP_BLTU] = "bltu",   [CPU_OP_BGEU] = "bgeu",

	[CPU_OP_JAL] = "jal",     [CPU_OP_JALR] = "jalr",

	[CPU_OP_FADD] = "fadd",   [CPU_OP_FSUB] = "fsub",   [CPU_OP_FMUL] = "fmul",
	[CPU_OP_FDIV] = "fdiv",   [CPU_OP_FSQRT] = "fsqrt", [CPU_OP_FMIN] = "fmin",
	[CPU_OP_FMAX] = "fmax",   [CPU_OP_FMADD] = "fmadd", [CPU_OP_FMSUB] = "fmsub",
	[CPU_OP_FSGNJ] = "fsgnj", [CPU_OP_FSGNJN] = "fsgnjn",
	[CPU_OP_FSGNJX] = "fsgnjx",
	[CPU_OP_FEQ] = "feq",     [CPU_OP_FLT] = "flt",     [CPU_OP_FLE] = "fle",
	[CPU_OP_FCLASS] = "fclass",
	[CPU_OP_FTOI] = "ftoi",   [CPU_OP_FTOU] = "ftou",   [CPU_OP_ITOF] = "itof",
	[CPU_OP_UTOF] = "utof",

	[CPU_OP_CLZ] = "clz",     [CPU_OP_CTZ] = "ctz",     [CPU_OP_POPCNT] = "popcnt",
	[CPU_OP_BSWAP] = "bswap", [CPU_OP_SEXTB] = "sext.b", [CPU_OP_SEXTH] = "sext.h",
	[CPU_OP_ROL] = "rol",     [CPU_OP_ROR] = "ror",     [CPU_OP_RORI] = "rori",
	[CPU_OP_MIN] = "min",     [CPU_OP_MAX] = "max",     [CPU_OP_MINU] = "minu",
	[CPU_OP_MAXU] = "maxu",
};

static const char* const disasm_cr_names[CPU_CR_COUNT] = {
	[CPU_CR_STATUS] = "status",
	[CPU_CR_EPC] = "epc",
	[CPU_CR_IVEC] = "ivec",
	[CPU_CR_SCRATCH] = "scratch",
	[CPU_CR_CAUSE] = "cause",
	[CPU_CR_BADADDR] = "badaddr",
	[CPU_CR_PTBR] = "ptbr",
	[CPU_CR_CYCLE] = "cycle",
	[CPU_CR_CYCLEH] = "cycleh",
	[CPU_CR_INSTRET] = "instret",
	[CPU_CR_INSTRETH] = "instreth",
	[CPU_CR_CPUID] = "cpuid",
	[CPU_CR_TADDR0] = "taddr0",
	[CPU_CR_TCTRL0] = "tctrl0",
	[CPU_CR_TADDR1] = "taddr1",
	[CPU_CR_TCTRL1] = "tctrl1",
	[CPU_CR_HARTID] = "hartid",
	[CPU_CR_FCSR] = "fcsr",
};

const char* disasm_cr_name(const uint32_t cr) {
	return cr < CPU_CR_COUNT ? disasm_cr_names[cr] : NULL;
}

// false for words mc/asm.py can't produce: reserved bits set, a control
// register MFCR/MTCR can't name, a shift by more than 31
static bool disasm_is_encodable(const cpu_instruction_t* in) {
	switch (in->format) {
		case CPU_FORMAT_INVALID:
			return false;
		case CPU_FORMAT_N:
			return !(in->raw & 0xFFFFFF00u);
		case CPU_FORMAT_R:
			return !(in->raw & 0xFF800000u)
				   && (!cpu_rs2_is_reserved(in->opcode) || !in->rs2);
		default:
			break;
	}
	switch (in->opcode) {
		case CPU_OP_MFCR:
			return !in->rs1 && in->imm < CPU_CR_COUNT;
		case CPU_OP_MTCR:
			// the counters, CPUID and HARTID are read-only
			return !in->rd && in->imm < CPU_CR_COUNT
				   && (in->imm < CPU_CR_CYCLE || in->imm > CPU_CR_CPUID)
				   && in->imm != CPU_CR_HARTID;
		case CPU_OP_TLBI:
			return !in->rd && in->imm < CPU_TLBI_MODE_COUNT
				   && (in->imm != CPU_TLBI_ALL || !in->rs1);
		case CPU_OP_SHLI:
		case CPU_OP_SHRI:
		case CPU_OP_SARI:
		case CPU_OP_RORI:
			return in->imm < 32;
	}
	return true;
}

void disasm_instruction(const uint32_t raw, const uint32_t pc, char* out,
						const size_t size) {
	const cpu_instruction_t in = cpu_decode(raw);
	const char* name = disasm_mnemonics[in.opcode];
	const unsigned rd = in.rd, rs1 = in.rs1, rs2 = in.rs2;
	const unsigned uimm = in.imm;
	const int simm = (int)(int32_t)in.imm;
	const unsigned target = (unsigned)(pc + (in.imm << 2)); // branch, JAL

	if (!name || !disasm_is_encodable(&in)) {
		snprintf(out, size, ".word 0x%08X", (unsigned)raw);
		return;
	}

	switch (in.opcode) {
		case CPU_OP_MFCR:
			snprintf(out, size, "%s r%u, %s", name, rd, disasm_cr_name(uimm));
			return;
		case CPU_OP_MTCR:
			snprintf(out, size, "%s %s, r%u", name, disasm_cr_name(uimm), rs1);
			return;
		case CPU_OP_TLBI:
			if (uimm == CPU_TLBI_ALL)
				snprintf(out, size, "%s.all", name);
			else
				snprintf(out,
						 size,
						 "%s%s r%u",
						 name,
						 uimm == CPU_TLBI_ASID ? ".asid" : "",
						 rs1);
			return;
		case CPU_OP_LL:
			snprintf(out, size, "%s r%u, (r%u)", name, rd, rs1);
			return;
		case CPU_OP_SC:
			snprintf(out, size, "%s r%u, r%u, (r%u)", name, rd, rs2, rs1);
			return;

		case CPU_OP_ANDI:
		case CPU_OP_ORI:
		case CPU_OP_XORI:
			snprintf(out, size, "%s r%u, r%u, 0x%X", name, rd, rs1, uimm);
			return;
		case CPU_OP_SHLI:
		case CPU_OP_SHRI:
		case CPU_OP_SARI:
		case CPU_OP_RORI:
			snprintf(out, size, "%s r%u, r%u, %u", name, rd, rs1, uimm);
			return;

		case CPU_OP_LUI:
		case CPU_OP_AUIPC:
			snprintf(out, size, "%s r%u, 0x%05X", name, rd, uimm >> 13);
			return;

		case CPU_OP_LB:
		case CPU_OP_LBU:
		case CPU_OP_LH:
		case CPU_OP_LHU:
		case CPU_OP_LW:
		case CPU_OP_SB:
		case CPU_OP_SH:
		case CPU_OP_SW:
			snprintf(out, size, "%s r%u, %d(r%u)", name, rd, simm, rs1);
			return;

		case CPU_OP_BEQ:
		case CPU_OP_BNE:
		case CPU_OP_BLT:
		case CPU_OP_BGE:
		case CPU_OP_BLTU:
		case CPU_OP_BGEU:
			snprintf(out, size, "%s r%u, r%u, 0x%08X", name, rd, rs1, target);
			return;

		case CPU_OP_JAL:
			snprintf(out, size, "%s r%u, 0x%08X", name, rd, target);
			return;
	}

	switch (in.format) {
		case CPU_FORMAT_N:
			snprintf(out, size, "%s", name);
			break;
		case CPU_FORMAT_R:
			// FSQRT, FCLASS, conversions, CLZ, ...
			if (cpu_rs2_is_reserved(in.opcode))
				snprintf(out, size, "%s r%u, r%u", name, rd, rs1);
			else
				snprintf(out, size, "%s r%u, r%u, r%u", name, rd, rs1, rs2);
			break;
		case CPU_FORMAT_I: // ADDI, SLTI, SLTIU, JALR
			snprintf(out, size, "%s r%u, r%u, %d", name, rd, rs1, simm);
			break;
		default:
			snprintf(out, size, ".word 0x%08X", (unsigned)raw);
			break;
	}
}
