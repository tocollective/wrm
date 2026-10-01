#include "cpu.h"

#include <math.h>
#include <string.h>

#include "disasm.h"

// Instruction layout (little-endian, 32-bit):
// [7:0] opcode, [12:8] rd, [17:13] rs1, [22:18] rs2
// I-format: imm14 = [31:18], U-format: imm19 = [31:13]
#define BITS(value, lo, len) (((value) >> (lo)) & ((1u << (len)) - 1u))

// Classic five-stage pipeline: IF -> ID -> EX -> MEM -> WB.
// - Stages are evaluated from WB back to IF, each reading the current
//   latches and filling the next ones, so the register file is written
//   in WB before ID reads it.
// - EX operands are forwarded from EX/MEM and MEM/WB.
// - A load followed by a dependent instruction stalls ID for one cycle.
// - Branches are predicted not taken and resolved in EX; a taken branch
//   squashes the two younger instructions in IF and ID.
// - Every fetch, load and store goes through the MMU. Faults (including
//   page faults) travel down the pipeline and are raised in WB (precise):
//   they enter the handler at IVEC and set STATUS.EXL, or halt when EXL is
//   already set (a fault inside the handler, or before software cleared
//   EXL after reset).
// - Interrupts are taken between two instructions when IE is set and EXL
//   clear: after WB has retired, the younger ones still in flight are
//   squashed and refetched on IRET.
// - Fetches use bus.fetch, which never reaches a device: IF runs ahead of
//   branch resolution, and a fetch down the wrong path must have no side
//   effects.
// - MFCR, MTCR and IRET wait in ID until the older instructions have left
//   EX and MEM, so control registers are read in EX and written in WB
//   without forwarding.
// - The mode (STATUS.UM) and the translation only change in WB, and every
//   change squashes the younger instructions: a trap, IRET (which jumps to
//   EPC when it retires), MTCR STATUS, MTCR PTBR and TLBI. So each stage
//   can check privileges against the current mode.

static uint32_t sign_extend(const uint32_t value, const int bits) {
	const uint32_t sign = 1u << (bits - 1);
	return (value ^ sign) - sign;
}

static uint32_t shift_right_arithmetic(const uint32_t value,
									   const uint32_t shift) {
	const uint32_t s = shift & 31;
	if (value & 0x80000000u) return (value >> s) | ~(UINT32_MAX >> s);
	return value >> s;
}

// Floating point: IEEE 754 binary32 in the GPRs, computed with the host's
// float, which rounds to nearest even. Every NaN result is the canonical
// one, so the outcome doesn't depend on how the host propagates payloads.
#define CPU_FP_NAN 0x7FC00000u
#define CPU_FP_SIGN 0x80000000u

static float fp_value(const uint32_t bits) {
	float f;
	memcpy(&f, &bits, sizeof(f));
	return f;
}

static uint32_t fp_result(const float f) {
	if (isnan(f)) return CPU_FP_NAN;
	uint32_t bits;
	memcpy(&bits, &f, sizeof(bits));
	return bits;
}

static bool fp_is_nan(const uint32_t bits) {
	return (bits & 0x7FFFFFFFu) > 0x7F800000u;
}

// FMIN/FMAX: a NaN operand is ignored, and -0 is less than +0
static uint32_t fp_min_max(const uint32_t a, const uint32_t b,
						   const bool max) {
	if (fp_is_nan(a)) return fp_is_nan(b) ? CPU_FP_NAN : b;
	if (fp_is_nan(b)) return a;
	const float fa = fp_value(a), fb = fp_value(b);
	if (fa == fb) return max ? a & b : a | b; // only zeros differ in bits
	return (max ? fa > fb : fa < fb) ? a : b;
}

// FCLASS: one bit set, from 0 = -inf up to 7 = +inf, 8 = signaling NaN,
// 9 = quiet NaN
static uint32_t fp_class(const uint32_t bits) {
	const bool negative = bits & CPU_FP_SIGN;
	const uint32_t exponent = BITS(bits, 23, 8);
	const uint32_t fraction = BITS(bits, 0, 23);
	if (exponent == 0xFF) {
		if (!fraction) return negative ? 1u << 0 : 1u << 7;
		return fraction & 0x400000u ? 1u << 9 : 1u << 8;
	}
	if (exponent) return negative ? 1u << 1 : 1u << 6;
	if (fraction) return negative ? 1u << 2 : 1u << 5;
	return negative ? 1u << 3 : 1u << 4;
}

// FTOI: rounds toward zero, saturates; NaN gives INT32_MAX
static uint32_t fp_to_int(const uint32_t bits) {
	const float f = fp_value(bits);
	if (isnan(f) || f >= 2147483648.0f) return INT32_MAX;
	if (f < -2147483648.0f) return (uint32_t)INT32_MIN;
	return (uint32_t)(int32_t)f;
}

// FTOU: rounds toward zero, saturates; NaN gives UINT32_MAX
static uint32_t fp_to_unsigned(const uint32_t bits) {
	const float f = fp_value(bits);
	if (isnan(f) || f >= 4294967296.0f) return UINT32_MAX;
	if (f <= -1.0f) return 0;
	return (uint32_t)f;
}

static uint32_t cpu_execute_fp(const uint8_t opcode, const uint32_t a,
							   const uint32_t b, const uint32_t d) {
	const float fa = fp_value(a), fb = fp_value(b), fd = fp_value(d);
	switch (opcode) {
		case CPU_OP_FADD:
			return fp_result(fa + fb);
		case CPU_OP_FSUB:
			return fp_result(fa - fb);
		case CPU_OP_FMUL:
			return fp_result(fa * fb);
		case CPU_OP_FDIV:
			return fp_result(fa / fb);
		case CPU_OP_FSQRT:
			return fp_result(sqrtf(fa));
		case CPU_OP_FMIN:
			return fp_min_max(a, b, false);
		case CPU_OP_FMAX:
			return fp_min_max(a, b, true);
		case CPU_OP_FMADD: // rounded once
			return fp_result(fmaf(fa, fb, fd));
		case CPU_OP_FMSUB:
			return fp_result(fmaf(-fa, fb, fd));
		case CPU_OP_FSGNJ:
			return (a & ~CPU_FP_SIGN) | (b & CPU_FP_SIGN);
		case CPU_OP_FSGNJN:
			return (a & ~CPU_FP_SIGN) | (~b & CPU_FP_SIGN);
		case CPU_OP_FSGNJX:
			return a ^ (b & CPU_FP_SIGN);
		case CPU_OP_FEQ: // false when either is NaN
			return fa == fb;
		case CPU_OP_FLT:
			return fa < fb;
		case CPU_OP_FLE:
			return fa <= fb;
		case CPU_OP_FCLASS:
			return fp_class(a);
		case CPU_OP_FTOI:
			return fp_to_int(a);
		case CPU_OP_FTOU:
			return fp_to_unsigned(a);
		case CPU_OP_ITOF:
			return fp_result((float)(int32_t)a);
		case CPU_OP_UTOF:
			return fp_result((float)a);
	}
	return 0;
}

cpu_t* cpu_create(const bus_t bus) {
	cpu_t* cpu = (cpu_t*)calloc(1, sizeof(cpu_t));
	if (!cpu) error("Failed to allocate CPU!");
	cpu->bus = bus;
	cpu->mmu = mmu_create(bus);
	cpu_reset(cpu);
	return cpu;
}

void cpu_destroy(cpu_t* cpu) {
	if (!cpu) return;
	mmu_destroy(cpu->mmu);
	cpu->mmu = NULL;
	free(cpu);
	cpu = NULL;
}

void cpu_reset(cpu_t* cpu) {
	if (!cpu) return;
	memset(cpu->gpr, 0, sizeof(cpu->gpr));
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
	memset(cpu->cr, 0, sizeof(cpu->cr));
	// no handler yet: faults halt until software clears EXL
	cpu->cr[CPU_CR_STATUS] = CPU_STATUS_EXL;
	mmu_reset(cpu->mmu);
	cpu->pc = CPU_PC_START;
	cpu->halted = false;
	cpu->halt_fault = 0;
	cpu->waiting = false;
	cpu->irq = false;
	cpu->cycles = 0;
	cpu->retired = 0;
	cpu->reservation_valid = false;
}

static cpu_format_t cpu_opcode_format(const uint8_t opcode) {
	switch (opcode) {
		case CPU_OP_HLT:
		case CPU_OP_NOP:
		case CPU_OP_WFI:
		case CPU_OP_IRET:
		case CPU_OP_SYSCALL:
		case CPU_OP_FENCE:
		case CPU_OP_BREAK:
			return CPU_FORMAT_N;

		case CPU_OP_ADD:
		case CPU_OP_SUB:
		case CPU_OP_AND:
		case CPU_OP_OR:
		case CPU_OP_XOR:
		case CPU_OP_SHL:
		case CPU_OP_SHR:
		case CPU_OP_SAR:
		case CPU_OP_SLT:
		case CPU_OP_SLTU:
		case CPU_OP_MUL:
		case CPU_OP_DIV:
		case CPU_OP_DIVU:
		case CPU_OP_REM:
		case CPU_OP_REMU:
		case CPU_OP_MULH:
		case CPU_OP_MULHU:
		case CPU_OP_MULHSU:
		case CPU_OP_LL:
		case CPU_OP_SC:
		case CPU_OP_FADD:
		case CPU_OP_FSUB:
		case CPU_OP_FMUL:
		case CPU_OP_FDIV:
		case CPU_OP_FSQRT:
		case CPU_OP_FMIN:
		case CPU_OP_FMAX:
		case CPU_OP_FMADD:
		case CPU_OP_FMSUB:
		case CPU_OP_FSGNJ:
		case CPU_OP_FSGNJN:
		case CPU_OP_FSGNJX:
		case CPU_OP_FEQ:
		case CPU_OP_FLT:
		case CPU_OP_FLE:
		case CPU_OP_FCLASS:
		case CPU_OP_FTOI:
		case CPU_OP_FTOU:
		case CPU_OP_ITOF:
		case CPU_OP_UTOF:
			return CPU_FORMAT_R;

		case CPU_OP_ADDI:
		case CPU_OP_ANDI:
		case CPU_OP_ORI:
		case CPU_OP_XORI:
		case CPU_OP_SHLI:
		case CPU_OP_SHRI:
		case CPU_OP_SARI:
		case CPU_OP_SLTI:
		case CPU_OP_SLTIU:
		case CPU_OP_MFCR:
		case CPU_OP_MTCR:
		case CPU_OP_TLBI:
		case CPU_OP_LB:
		case CPU_OP_LBU:
		case CPU_OP_LH:
		case CPU_OP_LHU:
		case CPU_OP_LW:
		case CPU_OP_SB:
		case CPU_OP_SH:
		case CPU_OP_SW:
		case CPU_OP_BEQ:
		case CPU_OP_BNE:
		case CPU_OP_BLT:
		case CPU_OP_BGE:
		case CPU_OP_BLTU:
		case CPU_OP_BGEU:
		case CPU_OP_JALR:
			return CPU_FORMAT_I;

		case CPU_OP_LUI:
		case CPU_OP_AUIPC:
		case CPU_OP_JAL:
			return CPU_FORMAT_U;
	}
	return CPU_FORMAT_INVALID;
}

cpu_instruction_t cpu_decode(const uint32_t raw) {
	cpu_instruction_t in = { 0 };
	in.raw = raw;
	in.opcode = BITS(raw, 0, 8);
	in.format = cpu_opcode_format(in.opcode);

	switch (in.format) {
		case CPU_FORMAT_INVALID:
		case CPU_FORMAT_N:
			break;
		case CPU_FORMAT_R: {
			in.rd = BITS(raw, 8, 5);
			in.rs1 = BITS(raw, 13, 5);
			in.rs2 = BITS(raw, 18, 5);
		} break;
		case CPU_FORMAT_I: {
			in.rd = BITS(raw, 8, 5);
			in.rs1 = BITS(raw, 13, 5);
			const uint32_t imm14 = BITS(raw, 18, 14);
			switch (in.opcode) {
				// logical and shift immediates are zero-extended
				case CPU_OP_ANDI:
				case CPU_OP_ORI:
				case CPU_OP_XORI:
				case CPU_OP_SHLI:
				case CPU_OP_SHRI:
				case CPU_OP_SARI:
					in.imm = imm14;
					break;
				default:
					in.imm = sign_extend(imm14, 14);
					break;
			}
		} break;
		case CPU_FORMAT_U: {
			in.rd = BITS(raw, 8, 5);
			if (in.opcode == CPU_OP_JAL) {
				in.imm = sign_extend(BITS(raw, 13, 19), 19);
			} else {
				in.imm = raw & 0xFFFFE000u; // imm19 << 13
			}
		} break;
	}

	return in;
}

// These instructions produce rd in MEM, too late for EX/MEM forwarding.
static bool cpu_result_in_mem(const cpu_instruction_t* in) {
	return (in->opcode >= CPU_OP_LB && in->opcode <= CPU_OP_LW)
		   || in->opcode == CPU_OP_LL || in->opcode == CPU_OP_SC;
}

static bool cpu_is_store(const cpu_instruction_t* in) {
	return in->opcode >= CPU_OP_SB && in->opcode <= CPU_OP_SW;
}

static bool cpu_is_atomic_write(const cpu_instruction_t* in) {
	return in->opcode == CPU_OP_SC;
}

static bool cpu_is_branch(const cpu_instruction_t* in) {
	return in->opcode >= CPU_OP_BEQ && in->opcode <= CPU_OP_BGEU;
}

// bytes a load or store accesses, 0 for other instructions
static uint8_t cpu_access_size(const cpu_instruction_t* in) {
	switch (in->opcode) {
		case CPU_OP_LB:
		case CPU_OP_LBU:
		case CPU_OP_SB:
			return 1;
		case CPU_OP_LH:
		case CPU_OP_LHU:
		case CPU_OP_SH:
			return 2;
		case CPU_OP_LW:
		case CPU_OP_SW:
		case CPU_OP_LL:
		case CPU_OP_SC:
			return 4;
	}
	return 0;
}

static uint32_t cpu_size_mask(const uint8_t size) {
	return size == 4 ? UINT32_MAX : (1u << (size * 8)) - 1;
}

// instructions that touch control registers
static bool cpu_is_serializing(const cpu_instruction_t* in) {
	return in->opcode == CPU_OP_MFCR || in->opcode == CPU_OP_MTCR
		   || in->opcode == CPU_OP_IRET;
}

// CYCLE, CYCLEH, INSTRET, INSTRETH
static bool cpu_cr_is_counter(const uint32_t cr) {
	return cr >= CPU_CR_CYCLE && cr <= CPU_CR_INSTRETH;
}

bool cpu_rs2_is_reserved(const uint8_t opcode) {
	switch (opcode) {
		case CPU_OP_LL:
		case CPU_OP_FSQRT:
		case CPU_OP_FCLASS:
		case CPU_OP_FTOI:
		case CPU_OP_FTOU:
		case CPU_OP_ITOF:
		case CPU_OP_UTOF:
			return true;
	}
	return false;
}

// reserved fields must be zero, otherwise it is an illegal instruction
static bool cpu_has_reserved_bits(const cpu_instruction_t* in) {
	switch (in->format) {
		case CPU_FORMAT_N:
			return in->raw & 0xFFFFFF00u;
		case CPU_FORMAT_R:
			return (in->raw & 0xFF800000u)
				   || (cpu_rs2_is_reserved(in->opcode) && in->rs2);
		default:
			break;
	}
	switch (in->opcode) {
		case CPU_OP_MFCR:
			return in->rs1;
		case CPU_OP_MTCR:
			return in->rd;
		case CPU_OP_TLBI:
			return in->rd || in->imm;
	}
	return false;
}

// MFCR/MTCR with a control register that doesn't exist, or MTCR to a
// read-only one
static bool cpu_cr_is_illegal(const cpu_instruction_t* in) {
	if (in->opcode != CPU_OP_MFCR && in->opcode != CPU_OP_MTCR) return false;
	if (in->imm >= CPU_CR_COUNT) return true;
	return in->opcode == CPU_OP_MTCR && cpu_cr_is_counter(in->imm);
}

// supervisor-only instructions
static bool cpu_is_privileged(const cpu_instruction_t* in) {
	switch (in->opcode) {
		case CPU_OP_HLT:
		case CPU_OP_WFI:
		case CPU_OP_IRET:
		case CPU_OP_MTCR:
		case CPU_OP_TLBI:
			return true;
		case CPU_OP_MFCR:
			return !cpu_cr_is_counter(in->imm); // counters are for everyone
	}
	return false;
}

static bool cpu_user_mode(const cpu_t* cpu) {
	return (cpu->cr[CPU_CR_STATUS] & CPU_STATUS_UM) != 0;
}

static bool cpu_writes_rd(const cpu_instruction_t* in) {
	switch (in->format) {
		case CPU_FORMAT_R:
		case CPU_FORMAT_U:
			return true;
		case CPU_FORMAT_I:
			return !cpu_is_store(in) && !cpu_is_branch(in)
				   && in->opcode != CPU_OP_MTCR && in->opcode != CPU_OP_TLBI;
		default:
			return false;
	}
}

static bool cpu_reads_reg(const cpu_instruction_t* in, const uint8_t reg) {
	const bool rs1 = in->format == CPU_FORMAT_R || in->format == CPU_FORMAT_I;
	const bool rs2 = in->format == CPU_FORMAT_R;
	const bool rd = cpu_is_store(in) || cpu_is_branch(in)
					|| in->opcode == CPU_OP_FMADD || in->opcode == CPU_OP_FMSUB;
	return (rs1 && in->rs1 == reg) || (rs2 && in->rs2 == reg)
		   || (rd && in->rd == reg);
}

static void cpu_latch_fault(cpu_latch_t* latch, const cpu_cause_t cause,
							const uint32_t value) {
	latch->fault = cause;
	latch->fault_value = value;
}

const char* cpu_cause_name(const uint8_t cause) {
	switch (cause) {
		case CPU_CAUSE_INTERRUPT:
			return "interrupt";
		case CPU_CAUSE_ILLEGAL_INSTRUCTION:
			return "illegal instruction";
		case CPU_CAUSE_MISALIGNED_FETCH:
			return "misaligned PC";
		case CPU_CAUSE_MISALIGNED_LOAD:
			return "misaligned load";
		case CPU_CAUSE_MISALIGNED_STORE:
			return "misaligned store";
		case CPU_CAUSE_FETCH_BUS_ERROR:
			return "instruction fetch bus error";
		case CPU_CAUSE_LOAD_BUS_ERROR:
			return "load bus error";
		case CPU_CAUSE_STORE_BUS_ERROR:
			return "store bus error";
		case CPU_CAUSE_FETCH_PAGE_FAULT:
			return "instruction fetch page fault";
		case CPU_CAUSE_LOAD_PAGE_FAULT:
			return "load page fault";
		case CPU_CAUSE_STORE_PAGE_FAULT:
			return "store page fault";
		case CPU_CAUSE_PRIVILEGED_INSTRUCTION:
			return "privileged instruction";
		case CPU_CAUSE_SYSCALL:
			return "syscall";
		case CPU_CAUSE_BREAK:
			return "breakpoint";
	}
	return "unknown fault";
}

// Stops the CPU, leaving pc as the architectural PC.
// fault is the cpu_cause_t that couldn't be handled, 0 for HLT.
// The pipeline keeps what was in flight (MEM/WB holds the instruction that
// halted), so cpu_dump can show it; nothing runs until a reset.
static void cpu_halt(cpu_t* cpu, const uint32_t pc, const uint8_t fault) {
	cpu->halted = true;
	cpu->halt_fault = fault;
	cpu->waiting = false;
	cpu->pc = pc;
}

// Sleeps until the IRQ line is asserted, then resumes at pc.
static void cpu_wait(cpu_t* cpu, const uint32_t pc) {
	cpu->waiting = true;
	cpu->pc = pc;
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
}

// Squashes everything in flight and fetches again from pc.
static void cpu_refetch(cpu_t* cpu, const uint32_t pc) {
	cpu->pc = pc;
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
}

// Enters the handler in supervisor mode:
// EPC = epc, PIE = IE, PUM = UM, IE = UM = 0, EXL = 1, pc = IVEC.
// Never called with EXL set, so IRET restores it by clearing it.
static void cpu_trap(cpu_t* cpu, const cpu_cause_t cause, const uint32_t epc) {
	cpu->reservation_valid = false;
	const uint32_t status = cpu->cr[CPU_CR_STATUS];
	uint32_t next = CPU_STATUS_EXL;
	if (status & CPU_STATUS_IE) next |= CPU_STATUS_PIE;
	if (status & CPU_STATUS_UM) next |= CPU_STATUS_PUM;
	cpu->cr[CPU_CR_STATUS] = next;
	cpu->cr[CPU_CR_CAUSE] = cause;
	cpu->cr[CPU_CR_EPC] = epc;
	cpu_refetch(cpu, cpu->cr[CPU_CR_IVEC]);
}

// Width of the instruction column in the trace and the dump
#define CPU_TEXT_WIDTH 28

static bool cpu_is_fetch_fault(const uint8_t fault) {
	return fault == CPU_CAUSE_MISALIGNED_FETCH
		   || fault == CPU_CAUSE_FETCH_BUS_ERROR
		   || fault == CPU_CAUSE_FETCH_PAGE_FAULT;
}

// Prints the address, word and instruction of a latch, then note if it
// isn't empty. A fetch that faulted has no word.
static void cpu_print_latch(FILE* out, const cpu_latch_t* latch,
							const char* note) {
	char text[DISASM_MAX_LENGTH] = "";
	if (cpu_is_fetch_fault(latch->fault)) {
		fprintf(out, "%08X  --------  ", (unsigned)latch->pc);
	} else {
		disasm_instruction(latch->in.raw, latch->pc, text, sizeof(text));
		fprintf(out,
				"%08X  %08X  ",
				(unsigned)latch->pc,
				(unsigned)latch->in.raw);
	}
	if (note[0])
		fprintf(out, "%-*s  %s", CPU_TEXT_WIDTH, text, note);
	else
		fputs(text, out);
}

static void cpu_format_fault(const cpu_latch_t* latch, char* out,
							 const size_t size) {
	snprintf(out,
			 size,
			 "! %s (0x%08X)",
			 cpu_cause_name(latch->fault),
			 (unsigned)latch->fault_value);
}

// One trace line per instruction that reaches WB, before it takes effect:
// cycle, address, word, instruction and what it changes (or its fault).
static void cpu_trace_wb(const cpu_t* cpu, const cpu_latch_t* wb) {
	const cpu_instruction_t* in = &wb->in;
	char note[64] = "";
	if (wb->fault) {
		cpu_format_fault(wb, note, sizeof(note));
	} else if (cpu_writes_rd(in) && in->rd != CPU_GPR_ZERO) {
		snprintf(note,
				 sizeof(note),
				 "r%u = 0x%08X",
				 (unsigned)in->rd,
				 (unsigned)wb->result);
	} else if (cpu_is_store(in)) {
		const uint8_t size = cpu_access_size(in);
		snprintf(note,
				 sizeof(note),
				 "[0x%08X] = 0x%0*X",
				 (unsigned)wb->result,
				 size * 2,
				 (unsigned)(wb->d & cpu_size_mask(size)));
	} else if (in->opcode == CPU_OP_MTCR) {
		snprintf(note,
				 sizeof(note),
				 "%s = 0x%08X",
				 disasm_cr_name(in->imm),
				 (unsigned)wb->result);
	} else if (in->opcode == CPU_OP_IRET) {
		snprintf(note,
				 sizeof(note),
				 "pc = 0x%08X",
				 (unsigned)cpu->cr[CPU_CR_EPC]);
	}

	fprintf(cpu->trace, "%10llu  ", (unsigned long long)cpu->cycles);
	cpu_print_latch(cpu->trace, wb, note);
	fputc('\n', cpu->trace);
}

// Trace line for an interrupt taken before the instruction at epc.
static void cpu_trace_interrupt(const cpu_t* cpu, const uint32_t epc) {
	fprintf(cpu->trace,
			"%10llu  %08X  --------  %-*s  ! interrupt\n",
			(unsigned long long)cpu->cycles,
			(unsigned)epc,
			CPU_TEXT_WIDTH,
			"");
}

static uint32_t cpu_read_cr(const cpu_t* cpu, const uint32_t cr) {
	switch (cr) {
		case CPU_CR_PTBR:
			return cpu->mmu->ptbr;
		case CPU_CR_CYCLE:
			return (uint32_t)cpu->cycles;
		case CPU_CR_CYCLEH:
			return (uint32_t)(cpu->cycles >> 32);
		case CPU_CR_INSTRET:
			return (uint32_t)cpu->retired;
		case CPU_CR_INSTRETH:
			return (uint32_t)(cpu->retired >> 32);
	}
	return cpu->cr[cr];
}

static void cpu_write_cr(cpu_t* cpu, const uint32_t cr, const uint32_t value) {
	switch (cr) {
		case CPU_CR_STATUS:
			cpu->cr[cr] = value & CPU_STATUS_MASK;
			break;
		case CPU_CR_PTBR:
			cpu->reservation_valid = false;
			mmu_set_ptbr(cpu->mmu, value);
			break;
		default:
			cpu->cr[cr] = value;
			break;
	}
}

// Returns the newest in-flight value of reg, falling back to value
// that was read from the register file in ID.
static uint32_t cpu_forward(const cpu_t* cpu, const uint8_t reg,
							const uint32_t value) {
	if (reg == CPU_GPR_ZERO) return 0;

	// A MEM-stage result cannot be here: the dependency stall keeps its
	// consumer out of EX until the producer has reached WB.
	const cpu_latch_t* mem = &cpu->pipeline.ex_mem;
	if (mem->valid && !mem->fault && cpu_writes_rd(&mem->in)
		&& mem->in.rd == reg)
		return mem->result;

	const cpu_latch_t* wb = &cpu->pipeline.mem_wb;
	if (wb->valid && !wb->fault && cpu_writes_rd(&wb->in) && wb->in.rd == reg)
		return wb->result;

	return value;
}

static void cpu_stage_if(cpu_t* cpu, cpu_latch_t* out) {
	*out = (cpu_latch_t){ 0 };
	out->valid = true;
	out->pc = cpu->pc;

	uint32_t raw = 0;
	uint32_t physical = 0;
	if (cpu->pc & 3) {
		cpu_latch_fault(out, CPU_CAUSE_MISALIGNED_FETCH, cpu->pc);
	} else if (mmu_translate(cpu->mmu,
							 cpu->pc,
							 MMU_ACCESS_EXECUTE,
							 cpu_user_mode(cpu),
							 &physical)) {
		cpu_latch_fault(out, CPU_CAUSE_FETCH_PAGE_FAULT, cpu->pc);
	} else if (cpu->bus.fetch(cpu->bus.ctx, physical, 4, &raw)) {
		cpu_latch_fault(out, CPU_CAUSE_FETCH_BUS_ERROR, cpu->pc);
	}
	out->in.raw = raw;

	cpu->pc += 4;
}

// returns true when ID has to stall
static bool cpu_stage_id(cpu_t* cpu, cpu_latch_t* out) {
	const cpu_latch_t* id = &cpu->pipeline.if_id;
	*out = (cpu_latch_t){ 0 };
	if (!id->valid) return false;
	if (id->fault) {
		*out = *id;
		return false;
	}

	const cpu_instruction_t in = cpu_decode(id->in.raw);

	// MEM-result dependency: wait until the producer leaves MEM
	const cpu_latch_t* ex = &cpu->pipeline.id_ex;
	if (ex->valid && !ex->fault && cpu_result_in_mem(&ex->in)
		&& ex->in.rd != CPU_GPR_ZERO && cpu_reads_reg(&in, ex->in.rd))
		return true;

	// control registers: wait until the older instructions leave EX and
	// MEM (the one in WB has already retired this cycle)
	if (cpu_is_serializing(&in)
		&& (ex->valid || cpu->pipeline.ex_mem.valid))
		return true;

	*out = *id;
	out->in = in;
	out->a = cpu->gpr[in.rs1];
	out->b = cpu->gpr[in.rs2];
	out->d = cpu->gpr[in.rd];
	if (in.format == CPU_FORMAT_INVALID || cpu_has_reserved_bits(&in)
		|| cpu_cr_is_illegal(&in))
		cpu_latch_fault(out, CPU_CAUSE_ILLEGAL_INSTRUCTION, in.raw);
	else if (cpu_is_privileged(&in) && cpu_user_mode(cpu))
		cpu_latch_fault(out, CPU_CAUSE_PRIVILEGED_INSTRUCTION, in.raw);
	else if (in.opcode == CPU_OP_SYSCALL)
		cpu_latch_fault(out, CPU_CAUSE_SYSCALL, 0);
	else if (in.opcode == CPU_OP_BREAK)
		cpu_latch_fault(out, CPU_CAUSE_BREAK, 0);
	else if (in.opcode == CPU_OP_LL && in.rs2 != 0)
		cpu_latch_fault(out, CPU_CAUSE_ILLEGAL_INSTRUCTION, in.raw);
	return false;
}

// returns true when control flow is redirected to target
static bool cpu_stage_ex(cpu_t* cpu, cpu_latch_t* out, uint32_t* target) {
	const cpu_latch_t* ex = &cpu->pipeline.id_ex;
	*out = *ex;
	if (!ex->valid || ex->fault) return false;

	const cpu_instruction_t* in = &ex->in;
	const uint32_t pc = ex->pc;
	const uint32_t a = cpu_forward(cpu, in->rs1, ex->a);
	const uint32_t b = cpu_forward(cpu, in->rs2, ex->b);
	const uint32_t d = cpu_forward(cpu, in->rd, ex->d);
	const uint32_t imm = in->imm;
	uint32_t r = 0;
	bool taken = false;
	uint32_t next_pc = pc + (imm << 2);

	switch (in->opcode) {
		case CPU_OP_ADD:
			r = a + b;
			break;
		case CPU_OP_SUB:
			r = a - b;
			break;
		case CPU_OP_AND:
			r = a & b;
			break;
		case CPU_OP_OR:
			r = a | b;
			break;
		case CPU_OP_XOR:
			r = a ^ b;
			break;
		case CPU_OP_SHL:
			r = a << (b & 31);
			break;
		case CPU_OP_SHR:
			r = a >> (b & 31);
			break;
		case CPU_OP_SAR:
			r = shift_right_arithmetic(a, b);
			break;
		case CPU_OP_SLT:
			r = (int32_t)a < (int32_t)b;
			break;
		case CPU_OP_SLTU:
			r = a < b;
			break;
		case CPU_OP_MUL:
			r = a * b;
			break;
		case CPU_OP_MULH:
			r = (uint32_t)(((uint64_t)a * b) >> 32)
				- ((a >> 31) ? b : 0) - ((b >> 31) ? a : 0);
			break;
		case CPU_OP_MULHU:
			r = (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32);
			break;
		case CPU_OP_MULHSU:
			r = (uint32_t)(((uint64_t)a * b) >> 32)
				- ((a >> 31) ? b : 0);
			break;
		case CPU_OP_DIV: {
			if (b == 0)
				r = UINT32_MAX;
			else if (a == 0x80000000u && b == UINT32_MAX)
				r = a;
			else
				r = (uint32_t)((int32_t)a / (int32_t)b);
		} break;
		case CPU_OP_DIVU:
			r = b ? a / b : UINT32_MAX;
			break;
		case CPU_OP_REM: {
			if (b == 0)
				r = a;
			else if (a == 0x80000000u && b == UINT32_MAX)
				r = 0;
			else
				r = (uint32_t)((int32_t)a % (int32_t)b);
		} break;
		case CPU_OP_REMU:
			r = b ? a % b : a;
			break;
		case CPU_OP_ADDI:
			r = a + imm;
			break;
		case CPU_OP_ANDI:
			r = a & imm;
			break;
		case CPU_OP_ORI:
			r = a | imm;
			break;
		case CPU_OP_XORI:
			r = a ^ imm;
			break;
		case CPU_OP_SHLI:
			r = a << (imm & 31);
			break;
		case CPU_OP_SHRI:
			r = a >> (imm & 31);
			break;
		case CPU_OP_SARI:
			r = shift_right_arithmetic(a, imm);
			break;
		case CPU_OP_SLTI:
			r = (int32_t)a < (int32_t)imm;
			break;
		case CPU_OP_SLTIU:
			r = a < imm;
			break;

		case CPU_OP_LUI:
			r = imm;
			break;
		case CPU_OP_AUIPC:
			r = pc + imm;
			break;

		// effective address
		case CPU_OP_LB:
		case CPU_OP_LBU:
		case CPU_OP_LH:
		case CPU_OP_LHU:
		case CPU_OP_LW:
		case CPU_OP_SB:
		case CPU_OP_SH:
		case CPU_OP_SW:
		case CPU_OP_LL:
		case CPU_OP_SC:
			r = a + ((in->format == CPU_FORMAT_R) ? 0 : imm);
			break;

		case CPU_OP_BEQ:
			taken = d == a;
			break;
		case CPU_OP_BNE:
			taken = d != a;
			break;
		case CPU_OP_BLT:
			taken = (int32_t)d < (int32_t)a;
			break;
		case CPU_OP_BGE:
			taken = (int32_t)d >= (int32_t)a;
			break;
		case CPU_OP_BLTU:
			taken = d < a;
			break;
		case CPU_OP_BGEU:
			taken = d >= a;
			break;

		case CPU_OP_JAL: {
			r = pc + 4;
			taken = true;
		} break;
		case CPU_OP_JALR: {
			r = pc + 4;
			taken = true;
			next_pc = (a + imm) & ~3u;
		} break;

		// control registers, no older instruction is in flight
		case CPU_OP_MFCR:
			r = cpu_read_cr(cpu, imm);
			break;
		case CPU_OP_MTCR:
		case CPU_OP_TLBI:
			r = a; // used in WB
			break;

		default:
			if (in->opcode >= CPU_OP_FADD && in->opcode <= CPU_OP_UTOF)
				r = cpu_execute_fp(in->opcode, a, b, d);
			break;
	}

	out->a = a;
	out->b = b;
	out->d = d;
	out->result = r;

	if (taken) *target = next_pc;
	return taken;
}

static void cpu_stage_mem(cpu_t* cpu, cpu_latch_t* out) {
	const cpu_latch_t* mem = &cpu->pipeline.ex_mem;
	*out = *mem;
	if (!mem->valid || mem->fault) return;

	const cpu_instruction_t* in = &mem->in;
	const uint32_t address = mem->result;
	const uint8_t size = cpu_access_size(in);
	if (!size) return; // no memory access

	const bool store = cpu_is_store(in) || cpu_is_atomic_write(in);
	if (address & (size - 1)) {
		cpu_latch_fault(out,
						store ? CPU_CAUSE_MISALIGNED_STORE
							  : CPU_CAUSE_MISALIGNED_LOAD,
						address);
		return;
	}

	uint32_t physical = 0;
	if ((in->opcode == CPU_OP_SC ? mmu_translate_probe : mmu_translate)(cpu->mmu,
					  address,
					  store ? MMU_ACCESS_WRITE : MMU_ACCESS_READ,
					  cpu_user_mode(cpu),
					  &physical)) {
		cpu_latch_fault(out,
						store ? CPU_CAUSE_STORE_PAGE_FAULT
							  : CPU_CAUSE_LOAD_PAGE_FAULT,
						address);
		return;
	}

	if (in->opcode == CPU_OP_SC) {
		const bool success = cpu->reservation_valid
			&& cpu->reservation_address == physical;
		cpu->reservation_valid = false;
		out->result = success ? 0 : 1;
		if (success) {
			if (mmu_translate(cpu->mmu, address, MMU_ACCESS_WRITE,
							  cpu_user_mode(cpu), &physical))
				cpu_latch_fault(out, CPU_CAUSE_STORE_PAGE_FAULT, address);
			else if (cpu->bus.write(cpu->bus.ctx, physical, 4, mem->b))
				cpu_latch_fault(out, CPU_CAUSE_STORE_BUS_ERROR, address);
		}
		return;
	}
	if (store) {
		const uint32_t mask = cpu_size_mask(size);
		if (cpu->bus.write(cpu->bus.ctx, physical, size, mem->d & mask))
			cpu_latch_fault(out, CPU_CAUSE_STORE_BUS_ERROR, address);
		return;
	}

	uint32_t value = 0;
	if (cpu->bus.read(cpu->bus.ctx, physical, size, &value)) {
		cpu_latch_fault(out, CPU_CAUSE_LOAD_BUS_ERROR, address);
		return;
	}
	if (in->opcode == CPU_OP_LL) {
		cpu->reservation_address = physical;
		cpu->reservation_valid = true;
	}

	switch (in->opcode) {
		case CPU_OP_LB:
			out->result = sign_extend(value, 8);
			break;
		case CPU_OP_LH:
			out->result = sign_extend(value, 16);
			break;
		default:
			out->result = value;
			break;
	}
}

// returns true when the pipeline was flushed (halted, waiting, trapped or
// refetching)
static bool cpu_stage_wb(cpu_t* cpu) {
	const cpu_latch_t* wb = &cpu->pipeline.mem_wb;
	if (!wb->valid) return false;
	if (cpu->trace) cpu_trace_wb(cpu, wb);

	if (wb->fault) {
		// a fault with EXL set can't be handled: the handler hasn't saved
		// EPC and the rest yet (or there is no handler after reset)
		if (cpu->cr[CPU_CR_STATUS] & CPU_STATUS_EXL) {
			warning("CPU fault at 0x%08X: %s (0x%08X)",
					(unsigned)wb->pc,
					cpu_cause_name(wb->fault),
					(unsigned)wb->fault_value);
			cpu_halt(cpu, wb->pc, wb->fault);
			return true;
		}
		cpu->cr[CPU_CR_BADADDR] = wb->fault_value;
		cpu_trap(cpu, (cpu_cause_t)wb->fault, wb->pc);
		return true;
	}

	if (cpu_writes_rd(&wb->in) && wb->in.rd != CPU_GPR_ZERO)
		cpu->gpr[wb->in.rd] = wb->result;
	cpu->retired++;

	switch (wb->in.opcode) {
		case CPU_OP_HLT:
			cpu_halt(cpu, wb->pc + 4, 0);
			return true;
		case CPU_OP_WFI:
			cpu_wait(cpu, wb->pc + 4);
			return true;
		case CPU_OP_MTCR:
			cpu_write_cr(cpu, wb->in.imm, wb->result);
			if (wb->in.imm == CPU_CR_STATUS || wb->in.imm == CPU_CR_PTBR) {
				cpu_refetch(cpu, wb->pc + 4);
				return true;
			}
			break;
		case CPU_OP_TLBI:
			cpu->reservation_valid = false;
			mmu_invalidate(cpu->mmu, wb->result);
			cpu_refetch(cpu, wb->pc + 4);
			return true;
		case CPU_OP_IRET: {
			// IE = PIE, UM = PUM, EXL = 0
			uint32_t status = cpu->cr[CPU_CR_STATUS];
			status &= ~(CPU_STATUS_IE | CPU_STATUS_UM | CPU_STATUS_EXL);
			if (status & CPU_STATUS_PIE) status |= CPU_STATUS_IE;
			if (status & CPU_STATUS_PUM) status |= CPU_STATUS_UM;
			cpu->cr[CPU_CR_STATUS] = status;
			cpu_refetch(cpu, cpu->cr[CPU_CR_EPC]);
			return true;
		}
	}
	return false;
}

// Address of the oldest instruction that has not retired yet.
static uint32_t cpu_next_pc(const cpu_t* cpu) {
	const cpu_pipeline_t* p = &cpu->pipeline;
	if (p->ex_mem.valid) return p->ex_mem.pc;
	if (p->id_ex.valid) return p->id_ex.pc;
	if (p->if_id.valid) return p->if_id.pc;
	return cpu->pc;
}

// Called after WB: squashes everything still in flight and jumps to IVEC.
// returns true when the interrupt was taken
static bool cpu_interrupt(cpu_t* cpu) {
	const uint32_t status = cpu->cr[CPU_CR_STATUS];
	if (!cpu->irq || !(status & CPU_STATUS_IE) || (status & CPU_STATUS_EXL))
		return false;
	const uint32_t epc = cpu_next_pc(cpu);
	if (cpu->trace) cpu_trace_interrupt(cpu, epc);
	cpu_trap(cpu, CPU_CAUSE_INTERRUPT, epc);
	return true;
}

void cpu_set_irq(cpu_t* cpu, const bool level) {
	if (!cpu) return;
	cpu->irq = level;
}

void cpu_invalidate_reservation(cpu_t* cpu, const uint32_t physical,
								const uint8_t size) {
	if (!cpu || !cpu->reservation_valid) return;
	const uint64_t first = physical;
	const uint64_t last = first + size - 1;
	const uint64_t reserved = cpu->reservation_address;
	if (first <= reserved + 3 && last >= reserved)
		cpu->reservation_valid = false;
}

void cpu_update(cpu_t* cpu) {
	if (!cpu || cpu->halted) return;
	cpu->cycles++;

	if (cpu->waiting) {
		if (!cpu->irq) return;
		cpu->waiting = false; // resumes at pc, or takes the interrupt below
	}

	cpu_pipeline_t next = { 0 }; // bubbles unless a stage fills them

	if (cpu_stage_wb(cpu)) return;
	if (cpu_interrupt(cpu)) return;
	cpu_stage_mem(cpu, &next.mem_wb);

	uint32_t target = 0;
	if (cpu_stage_ex(cpu, &next.ex_mem, &target)) {
		// mispredicted: squash ID and IF, fetch from target next cycle
		cpu->pc = target;
	} else if (cpu_stage_id(cpu, &next.id_ex)) {
		// stalled: keep IF/ID and PC, bubble goes to EX
		next.if_id = cpu->pipeline.if_id;
	} else {
		cpu_stage_if(cpu, &next.if_id);
	}

	cpu->pipeline = next;
}

void cpu_dump(const cpu_t* cpu, FILE* out) {
	if (!cpu || !out) return;
	const cpu_pipeline_t* p = &cpu->pipeline;

	fputs("CPU: ", out);
	if (cpu->halted && cpu->halt_fault) {
		fprintf(out,
				"halted by a fault at 0x%08X: %s (0x%08X)\n",
				(unsigned)cpu->pc,
				cpu_cause_name(cpu->halt_fault),
				(unsigned)p->mem_wb.fault_value);
	} else if (cpu->halted) {
		fputs("halted (HLT)\n", out);
	} else if (cpu->waiting) {
		fputs("waiting for an interrupt (WFI)\n", out);
	} else {
		fputs("running\n", out);
	}
	fprintf(out,
			"  pc %08X  cycles %llu  retired %llu  irq %d\n",
			(unsigned)cpu->pc,
			(unsigned long long)cpu->cycles,
			(unsigned long long)cpu->retired,
			cpu->irq ? 1 : 0);

	for (int i = 0; i < CPU_GPR_COUNT; i++) {
		fprintf(out, "  r%-2d %08X", i, (unsigned)cpu->gpr[i]);
		if (i % 4 == 3) fputc('\n', out);
	}

	// the counters are above
	for (uint32_t cr = 0; cr < CPU_CR_CYCLE; cr++) {
		const uint32_t value = cpu_read_cr(cpu, cr);
		fprintf(out, "  %-8s %08X", disasm_cr_name(cr), (unsigned)value);
		if (cr == CPU_CR_STATUS) {
			static const char* const flags[] = { "IE", "PIE", "UM", "PUM",
												 "EXL" };
			fputs(" ", out);
			for (int bit = 0; bit < 5; bit++)
				if (value & (1u << bit)) fprintf(out, " %s", flags[bit]);
		} else if (cr == CPU_CR_CAUSE) {
			fprintf(out, "  %s", cpu_cause_name(value));
		} else if (cr == CPU_CR_PTBR) {
			fputs(value & MMU_PTBR_ENABLE ? "  paging on" : "  paging off",
				  out);
		}
		fputc('\n', out);
	}

	// oldest first
	const struct {
		const char* name;
		const cpu_latch_t* latch;
	} stages[] = {
		{ "MEM/WB", &p->mem_wb },
		{ "EX/MEM", &p->ex_mem },
		{ "ID/EX", &p->id_ex },
		{ "IF/ID", &p->if_id },
	};
	for (size_t i = 0; i < sizeof(stages) / sizeof(stages[0]); i++) {
		const cpu_latch_t* latch = stages[i].latch;
		fprintf(out, "  %-7s ", stages[i].name);
		if (!latch->valid) {
			fputs("bubble\n", out);
			continue;
		}
		char note[64] = "";
		if (latch->fault) cpu_format_fault(latch, note, sizeof(note));
		cpu_print_latch(out, latch, note);
		fputc('\n', out);
	}
	fflush(out);
}
