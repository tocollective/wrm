#ifndef WRM_CPU_H
#define WRM_CPU_H
#include "common.h"

#include "bus.h"
#include "mmu.h"

#define CPU_GPR_COUNT 32
#define CPU_GPR_ZERO 0
#define CPU_GPR_RA 1 // return address
#define CPU_GPR_SP 2 // stack pointer
#define CPU_GPR_GP 3 // global pointer
#define CPU_GPR_FP 4 // global pointer
#define CPU_PC_START 0xFE000000 // reset vector: start of ROM (MB_ROM_BASE)

// Control registers, accessed with MFCR/MTCR (see docs/INSTRUCTIONS.md)
typedef enum cpu_cr {
	CPU_CR_STATUS = 0,
	CPU_CR_EPC = 1, // where IRET returns to
	CPU_CR_IVEC = 2, // interrupt handler address
	CPU_CR_SCRATCH = 3, // free for the handler
	CPU_CR_CAUSE = 4, // why the handler was entered, cpu_cause_t
	CPU_CR_BADADDR = 5, // faulting address or instruction
	CPU_CR_PTBR = 6, // page table base, held by the MMU
	// read-only counters, also readable in user mode
	CPU_CR_CYCLE = 7, // clock cycles since reset, low 32 bits
	CPU_CR_CYCLEH = 8, // high 32 bits
	CPU_CR_INSTRET = 9, // instructions retired since reset, low 32 bits
	CPU_CR_INSTRETH = 10, // high 32 bits
	CPU_CR_COUNT,
} cpu_cr_t;

#define CPU_STATUS_IE 0x01 // interrupts enabled
#define CPU_STATUS_PIE 0x02 // IE before the handler was entered
#define CPU_STATUS_UM 0x04 // user mode, 0 = supervisor
#define CPU_STATUS_PUM 0x08 // UM before the handler was entered
#define CPU_STATUS_MASK                                                        \
	(CPU_STATUS_IE | CPU_STATUS_PIE | CPU_STATUS_UM | CPU_STATUS_PUM)

// CAUSE values (see docs/INSTRUCTIONS.md#exceptions)
typedef enum cpu_cause {
	CPU_CAUSE_INTERRUPT = 0, // never set in a latch: 0 there means no fault
	CPU_CAUSE_ILLEGAL_INSTRUCTION = 1,
	CPU_CAUSE_MISALIGNED_FETCH = 2,
	CPU_CAUSE_MISALIGNED_LOAD = 3,
	CPU_CAUSE_MISALIGNED_STORE = 4,
	CPU_CAUSE_FETCH_BUS_ERROR = 5,
	CPU_CAUSE_LOAD_BUS_ERROR = 6,
	CPU_CAUSE_STORE_BUS_ERROR = 7,
	CPU_CAUSE_FETCH_PAGE_FAULT = 8,
	CPU_CAUSE_LOAD_PAGE_FAULT = 9,
	CPU_CAUSE_STORE_PAGE_FAULT = 10,
	CPU_CAUSE_PRIVILEGED_INSTRUCTION = 11, // supervisor only, run in user mode
	CPU_CAUSE_SYSCALL = 12,
} cpu_cause_t;

// See docs/INSTRUCTIONS.md
typedef enum cpu_opcode {
	CPU_OP_HLT = 0x00, // supervisor
	CPU_OP_NOP = 0x01,
	CPU_OP_WFI = 0x02, // supervisor
	CPU_OP_IRET = 0x03, // supervisor
	CPU_OP_MFCR = 0x04, // I-format, supervisor
	CPU_OP_MTCR = 0x05, // I-format, supervisor
	CPU_OP_TLBI = 0x06, // I-format, only rs1, supervisor
	CPU_OP_SYSCALL = 0x07,

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
	uint8_t fault; // cpu_cause_t, 0 = no fault, raised when retired in WB
	uint32_t fault_value; // BADADDR
} cpu_latch_t;

typedef struct cpu_pipeline {
	cpu_latch_t if_id;
	cpu_latch_t id_ex;
	cpu_latch_t ex_mem;
	cpu_latch_t mem_wb;
} cpu_pipeline_t;

typedef struct cpu {
	uint32_t gpr[CPU_GPR_COUNT]; // general purpose registers
	uint32_t pc; // fetch address; architectural PC once halted or waiting
	uint32_t cr[CPU_CR_COUNT]; // control registers
	bool halted;
	uint8_t halt_fault; // cpu_cause_t of the fault that halted it, 0 = HLT
	bool waiting; // WFI: sleeping until the IRQ line is asserted
	bool irq; // IRQ input line, driven by the PIC
	uint64_t cycles; // clock cycles, CYCLE/CYCLEH
	uint64_t retired; // instructions completed in WB, INSTRET/INSTRETH
	cpu_pipeline_t pipeline;
	mmu_t* mmu; // translates every fetch, load and store
	bus_t bus; // physical memory
} cpu_t;

cpu_t* cpu_create(const bus_t bus);
void cpu_destroy(cpu_t* cpu);

void cpu_reset(cpu_t* cpu);
void cpu_update(cpu_t* cpu); // advances the pipeline by one clock cycle
void cpu_set_irq(cpu_t* cpu, const bool level);

cpu_instruction_t cpu_decode(const uint32_t raw);

#endif // WRM_CPU_H
