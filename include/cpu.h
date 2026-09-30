#ifndef WRM_CPU_H
#define WRM_CPU_H
#include "common.h"

#include "bus.h"

#define CPU_GPR_COUNT 32
#define CPU_GPR_ZERO 0
#define CPU_PC_START 0xFE000000 // reset vector: start of ROM (MB_ROM_BASE)

// See docs/INSTRUCTIONS.md
typedef enum cpu_opcode {
	CPU_OP_HLT = 0x00,
	CPU_OP_NOP = 0x01,

	// R-format ALU
	CPU_OP_ADD = 0x10,
	CPU_OP_SUB = 0x11,
	CPU_OP_AND = 0x12,
	CPU_OP_OR = 0x13,
	CPU_OP_XOR = 0x14,
	CPU_OP_SHL = 0x15,
	CPU_OP_SHR = 0x16,
	CPU_OP_SAR = 0x17,
	CPU_OP_SLT = 0x18,
	CPU_OP_SLTU = 0x19,
	CPU_OP_MUL = 0x1A,
	CPU_OP_DIV = 0x1B,
	CPU_OP_DIVU = 0x1C,
	CPU_OP_REM = 0x1D,
	CPU_OP_REMU = 0x1E,

	// I-format ALU
	CPU_OP_ADDI = 0x20,
	CPU_OP_ANDI = 0x22,
	CPU_OP_ORI = 0x23,
	CPU_OP_XORI = 0x24,
	CPU_OP_SHLI = 0x25,
	CPU_OP_SHRI = 0x26,
	CPU_OP_SARI = 0x27,
	CPU_OP_SLTI = 0x28,
	CPU_OP_SLTIU = 0x29,

	// U-format
	CPU_OP_LUI = 0x30,
	CPU_OP_AUIPC = 0x31,

	// loads (I-format)
	CPU_OP_LB = 0x40,
	CPU_OP_LBU = 0x41,
	CPU_OP_LH = 0x42,
	CPU_OP_LHU = 0x43,
	CPU_OP_LW = 0x44,

	// stores (I-format, rd is the source)
	CPU_OP_SB = 0x48,
	CPU_OP_SH = 0x49,
	CPU_OP_SW = 0x4A,

	// branches (I-format, compares rd with rs1)
	CPU_OP_BEQ = 0x50,
	CPU_OP_BNE = 0x51,
	CPU_OP_BLT = 0x52,
	CPU_OP_BGE = 0x53,
	CPU_OP_BLTU = 0x54,
	CPU_OP_BGEU = 0x55,

	// jumps
	CPU_OP_JAL = 0x60, // U-format
	CPU_OP_JALR = 0x61, // I-format
} cpu_opcode_t;

typedef enum cpu_format {
	CPU_FORMAT_INVALID = 0,
	CPU_FORMAT_N, // opcode only
	CPU_FORMAT_R,
	CPU_FORMAT_I,
	CPU_FORMAT_U,
} cpu_format_t;

typedef struct cpu_instruction {
	uint32_t raw;
	uint8_t opcode;
	cpu_format_t format;
	uint8_t rd;
	uint8_t rs1;
	uint8_t rs2;
	uint32_t imm; // already sign/zero extended
} cpu_instruction_t;

// Pipeline register between two stages. !valid = bubble.
typedef struct cpu_latch {
	bool valid;
	uint32_t pc; // address of this instruction
	cpu_instruction_t in; // only in.raw is set in IF/ID
	uint32_t a, b, d; // rs1, rs2, rd source values
	uint32_t result; // ALU result, link address, load address/data
	const char* fault; // NULL = no fault, raised when retired in WB
	uint32_t fault_value;
} cpu_latch_t;

typedef struct cpu_pipeline {
	cpu_latch_t if_id;
	cpu_latch_t id_ex;
	cpu_latch_t ex_mem;
	cpu_latch_t mem_wb;
} cpu_pipeline_t;

typedef struct cpu {
	uint32_t gpr[CPU_GPR_COUNT]; // general purpose registers
	uint32_t pc; // fetch address; architectural PC once halted
	bool halted;
	uint64_t cycles; // clock cycles
	uint64_t retired; // instructions completed in WB
	cpu_pipeline_t pipeline;
	bus_t bus;
} cpu_t;

cpu_t* cpu_create(const bus_t bus);
void cpu_destroy(cpu_t* cpu);

void cpu_reset(cpu_t* cpu);
void cpu_update(cpu_t* cpu); // advances the pipeline by one clock cycle

cpu_instruction_t cpu_decode(const uint32_t raw);

#endif // WRM_CPU_H
