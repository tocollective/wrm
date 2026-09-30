#include "cpu.h"

#include <string.h>

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
// - Faults travel down the pipeline and are raised in WB (precise).
// - Interrupts are taken between two instructions: after WB has retired,
//   the younger ones still in flight are squashed and refetched on IRET.
// - MFCR, MTCR and IRET wait in ID until the older instructions have left
//   EX and MEM, so control registers are read in EX and written in WB
//   without forwarding.

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

cpu_t* cpu_create(const bus_t bus) {
	cpu_t* cpu = (cpu_t*)calloc(1, sizeof(cpu_t));
	if (!cpu) error("Failed to allocate CPU!");
	cpu->bus = bus;
	cpu_reset(cpu);
	return cpu;
}

void cpu_destroy(cpu_t* cpu) {
	if (!cpu) return;
	free(cpu);
	cpu = NULL;
}

void cpu_reset(cpu_t* cpu) {
	if (!cpu) return;
	memset(cpu->gpr, 0, sizeof(cpu->gpr));
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
	memset(cpu->cr, 0, sizeof(cpu->cr));
	cpu->pc = CPU_PC_START;
	cpu->halted = false;
	cpu->waiting = false;
	cpu->irq = false;
	cpu->cycles = 0;
	cpu->retired = 0;
}

static cpu_format_t cpu_opcode_format(const uint8_t opcode) {
	switch (opcode) {
		case CPU_OP_HLT:
		case CPU_OP_NOP:
		case CPU_OP_WFI:
		case CPU_OP_IRET:
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

static bool cpu_is_load(const cpu_instruction_t* in) {
	return in->opcode >= CPU_OP_LB && in->opcode <= CPU_OP_LW;
}

static bool cpu_is_store(const cpu_instruction_t* in) {
	return in->opcode >= CPU_OP_SB && in->opcode <= CPU_OP_SW;
}

static bool cpu_is_branch(const cpu_instruction_t* in) {
	return in->opcode >= CPU_OP_BEQ && in->opcode <= CPU_OP_BGEU;
}

// instructions that touch control registers
static bool cpu_is_serializing(const cpu_instruction_t* in) {
	return in->opcode == CPU_OP_MFCR || in->opcode == CPU_OP_MTCR
		   || in->opcode == CPU_OP_IRET;
}

static bool cpu_writes_rd(const cpu_instruction_t* in) {
	switch (in->format) {
		case CPU_FORMAT_R:
		case CPU_FORMAT_U:
			return true;
		case CPU_FORMAT_I:
			return !cpu_is_store(in) && !cpu_is_branch(in)
				   && in->opcode != CPU_OP_MTCR;
		default:
			return false;
	}
}

static bool cpu_reads_reg(const cpu_instruction_t* in, const uint8_t reg) {
	const bool rs1 = in->format == CPU_FORMAT_R || in->format == CPU_FORMAT_I;
	const bool rs2 = in->format == CPU_FORMAT_R;
	const bool rd = cpu_is_store(in) || cpu_is_branch(in);
	return (rs1 && in->rs1 == reg) || (rs2 && in->rs2 == reg)
		   || (rd && in->rd == reg);
}

static void cpu_latch_fault(cpu_latch_t* latch, const char* reason,
							const uint32_t value) {
	latch->fault = reason;
	latch->fault_value = value;
}

// Stops the CPU, leaving pc as the architectural PC.
static void cpu_halt(cpu_t* cpu, const uint32_t pc) {
	cpu->halted = true;
	cpu->waiting = false;
	cpu->pc = pc;
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
}

// Sleeps until the IRQ line is asserted, then resumes at pc.
static void cpu_wait(cpu_t* cpu, const uint32_t pc) {
	cpu->waiting = true;
	cpu->pc = pc;
	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
}

static void cpu_write_cr(cpu_t* cpu, const uint32_t cr, const uint32_t value) {
	if (cr == CPU_CR_STATUS) {
		cpu->cr[cr] = value & CPU_STATUS_MASK;
	} else {
		cpu->cr[cr] = value;
	}
}

// Returns the newest in-flight value of reg, falling back to value
// that was read from the register file in ID.
static uint32_t cpu_forward(const cpu_t* cpu, const uint8_t reg,
							const uint32_t value) {
	if (reg == CPU_GPR_ZERO) return 0;

	// Never a load here: the load-use stall keeps a dependent instruction
	// out of EX until the load has reached WB.
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
	if (cpu->pc & 3) {
		cpu_latch_fault(out, "misaligned PC", cpu->pc);
	} else if (cpu->bus.read(cpu->bus.ctx, cpu->pc, 4, &raw)) {
		cpu_latch_fault(out, "instruction fetch bus error", cpu->pc);
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

	// load-use hazard: wait until the load leaves MEM
	const cpu_latch_t* ex = &cpu->pipeline.id_ex;
	if (ex->valid && !ex->fault && cpu_is_load(&ex->in)
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
	if (in.format == CPU_FORMAT_INVALID)
		cpu_latch_fault(out, "illegal instruction", in.raw);
	else if ((in.opcode == CPU_OP_MFCR || in.opcode == CPU_OP_MTCR)
			 && in.imm >= CPU_CR_COUNT)
		cpu_latch_fault(out, "illegal control register", in.imm);
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
			r = a + imm;
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
			r = cpu->cr[imm];
			break;
		case CPU_OP_MTCR:
			r = a; // written in WB
			break;
		case CPU_OP_IRET: {
			taken = true;
			next_pc = cpu->cr[CPU_CR_EPC];
		} break;
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
	uint8_t size = 0;
	switch (in->opcode) {
		case CPU_OP_LB:
		case CPU_OP_LBU:
		case CPU_OP_SB:
			size = 1;
			break;
		case CPU_OP_LH:
		case CPU_OP_LHU:
		case CPU_OP_SH:
			size = 2;
			break;
		case CPU_OP_LW:
		case CPU_OP_SW:
			size = 4;
			break;
		default:
			return; // no memory access
	}

	if (address & (size - 1)) {
		const bool store = cpu_is_store(in);
		cpu_latch_fault(
			out, store ? "misaligned store" : "misaligned load", address);
		return;
	}

	if (cpu_is_store(in)) {
		const uint32_t mask = size == 4 ? UINT32_MAX : (1u << (size * 8)) - 1;
		if (cpu->bus.write(cpu->bus.ctx, address, size, mem->d & mask))
			cpu_latch_fault(out, "store bus error", address);
		return;
	}

	uint32_t value = 0;
	if (cpu->bus.read(cpu->bus.ctx, address, size, &value)) {
		cpu_latch_fault(out, "load bus error", address);
		return;
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

// returns true when the pipeline was flushed (halted or waiting)
static bool cpu_stage_wb(cpu_t* cpu) {
	const cpu_latch_t* wb = &cpu->pipeline.mem_wb;
	if (!wb->valid) return false;

	if (wb->fault) {
		warning("CPU fault at 0x%08X: %s (0x%08X)",
				(unsigned)wb->pc,
				wb->fault,
				(unsigned)wb->fault_value);
		cpu_halt(cpu, wb->pc);
		return true;
	}

	if (cpu_writes_rd(&wb->in) && wb->in.rd != CPU_GPR_ZERO)
		cpu->gpr[wb->in.rd] = wb->result;
	cpu->retired++;

	switch (wb->in.opcode) {
		case CPU_OP_HLT:
			cpu_halt(cpu, wb->pc + 4);
			return true;
		case CPU_OP_WFI:
			cpu_wait(cpu, wb->pc + 4);
			return true;
		case CPU_OP_MTCR:
			cpu_write_cr(cpu, wb->in.imm, wb->result);
			break;
		case CPU_OP_IRET: {
			uint32_t status = cpu->cr[CPU_CR_STATUS] & ~CPU_STATUS_IE;
			if (status & CPU_STATUS_PIE) status |= CPU_STATUS_IE;
			cpu->cr[CPU_CR_STATUS] = status;
		} break;
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
	uint32_t status = cpu->cr[CPU_CR_STATUS];
	if (!cpu->irq || !(status & CPU_STATUS_IE)) return false;

	cpu->cr[CPU_CR_EPC] = cpu_next_pc(cpu);
	status = (status & ~CPU_STATUS_IE) | CPU_STATUS_PIE;
	cpu->cr[CPU_CR_STATUS] = status;

	memset(&cpu->pipeline, 0, sizeof(cpu->pipeline));
	cpu->pc = cpu->cr[CPU_CR_IVEC];
	return true;
}

void cpu_set_irq(cpu_t* cpu, const bool level) {
	if (!cpu) return;
	cpu->irq = level;
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
