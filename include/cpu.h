#ifndef WRM_CPU_H
#define WRM_CPU_H
#include "common.h"

#include <stdio.h>

#include "bus.h"
#include "mmu.h"

#define CPU_GPR_COUNT 32
#define CPU_GPR_ZERO 0 // always reads as zero, the only role the hardware fixes
// software roles from docs/ABI.md
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
	// read-only, supervisor
	CPU_CR_CPUID = 11, // ISA version and extensions
	// debug triggers, see CPU_TCTRL_*
	CPU_CR_TADDR0 = 12,
	CPU_CR_TCTRL0 = 13,
	CPU_CR_TADDR1 = 14,
	CPU_CR_TCTRL1 = 15,
	// read-only, supervisor: this core's number, always 0 (one core)
	CPU_CR_HARTID = 16,
	// floating-point exception flags and rounding mode, also for user mode
	CPU_CR_FCSR = 17,
	CPU_CR_COUNT,
} cpu_cr_t;

// FCSR: the flags are SF_FLAG_*, which FP instructions set when they
// retire; FRM is the sf_rounding_t of the ones that round. Other bits read
// as zero; a write of a reserved FRM (5-7) leaves FRM as it was.
#define CPU_FCSR_FLAGS_MASK 0x1F
#define CPU_FCSR_FRM_SHIFT 5
#define CPU_FCSR_FRM_MASK 0xE0

#define CPU_TRIGGER_COUNT 2 // TADDRn = TADDR0 + 2n, TCTRLn = TCTRL0 + 2n

// TCTRL: what a trigger matches, in the range of 2^SIZE bytes that holds
// TADDR. A match raises CPU_CAUSE_WATCH before the instruction runs.
#define CPU_TCTRL_X 0x01 // instruction fetch
#define CPU_TCTRL_R 0x02 // load
#define CPU_TCTRL_W 0x04 // store
#define CPU_TCTRL_SIZE_SHIFT 8 // bits 12:8: log2 of the range in bytes
#define CPU_TCTRL_SIZE_MASK 0x1F00
#define CPU_TCTRL_MASK                                                         \
	(CPU_TCTRL_X | CPU_TCTRL_R | CPU_TCTRL_W | CPU_TCTRL_SIZE_MASK)

// CPUID: the ISA version in bits 31:24, the extensions below
#define CPU_CPUID_VERSION 1
#define CPU_CPUID_MMU 0x01 // paging and TLBI
#define CPU_CPUID_FPU 0x02 // binary32 floating point in the GPRs
#define CPU_CPUID_ATOMIC 0x04 // LL and SC
#define CPU_CPUID_MULH 0x08 // MULH, MULHU and MULHSU
#define CPU_CPUID_TLBI_MODES 0x10 // TLBI of an ASID and of the whole TLB
#define CPU_CPUID_DEBUG 0x20 // STATUS.SS and the triggers
#define CPU_CPUID_BITS 0x40 // bit manipulation: CLZ, ROR, MIN, ...
#define CPU_CPUID_FCSR 0x80 // FP exception flags and rounding modes
#define CPU_CPUID                                                              \
	(CPU_CPUID_VERSION << 24 | CPU_CPUID_MMU | CPU_CPUID_FPU                   \
	 | CPU_CPUID_ATOMIC | CPU_CPUID_MULH | CPU_CPUID_TLBI_MODES               \
	 | CPU_CPUID_DEBUG | CPU_CPUID_BITS | CPU_CPUID_FCSR)

// TLBI modes, in imm14
typedef enum cpu_tlbi_mode {
	CPU_TLBI_PAGE = 0, // the page at rs1, current ASID and global entries
	CPU_TLBI_ASID = 1, // every non-global entry of the ASID in rs1[7:0]
	CPU_TLBI_ALL = 2, // the whole TLB, global entries too; rs1 is reserved
	CPU_TLBI_MODE_COUNT,
} cpu_tlbi_mode_t;

#define CPU_STATUS_IE 0x01 // interrupts enabled
#define CPU_STATUS_PIE 0x02 // IE before the handler was entered
#define CPU_STATUS_UM 0x04 // user mode, 0 = supervisor
#define CPU_STATUS_PUM 0x08 // UM before the handler was entered
#define CPU_STATUS_EXL 0x10 // in the handler: faults halt, no interrupts
#define CPU_STATUS_SS 0x20 // single step: a trap after each instruction
#define CPU_STATUS_PSS 0x40 // SS before the handler was entered
#define CPU_STATUS_MASK                                                        \
	(CPU_STATUS_IE | CPU_STATUS_PIE | CPU_STATUS_UM | CPU_STATUS_PUM           \
	 | CPU_STATUS_EXL | CPU_STATUS_SS | CPU_STATUS_PSS)

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
	CPU_CAUSE_BREAK = 13,
	CPU_CAUSE_STEP = 14, // after an instruction run with STATUS.SS
	CPU_CAUSE_WATCH = 15, // a trigger matched
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
	CPU_OP_FENCE = 0x08,
	CPU_OP_BREAK = 0x09,

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
	CPU_OP_MULH = 0x1F,
	CPU_OP_MULHU = 0x2A,
	CPU_OP_MULHSU = 0x2B,

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
	CPU_OP_LL = 0x4B, // R-format: rd = *(rs1), rs2 must be zero
	CPU_OP_SC = 0x4C, // R-format: *(rs1) = rs2, rd = 0 on success

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

	// floating point (R-format): IEEE 754 binary32 held in the GPRs
	CPU_OP_FADD = 0x70,
	CPU_OP_FSUB = 0x71,
	CPU_OP_FMUL = 0x72,
	CPU_OP_FDIV = 0x73,
	CPU_OP_FSQRT = 0x74, // rs2 must be zero
	CPU_OP_FMIN = 0x75,
	CPU_OP_FMAX = 0x76,
	CPU_OP_FMADD = 0x77, // rd = rd + rs1 * rs2, also reads rd
	CPU_OP_FMSUB = 0x78, // rd = rd - rs1 * rs2, also reads rd
	CPU_OP_FSGNJ = 0x79,
	CPU_OP_FSGNJN = 0x7A,
	CPU_OP_FSGNJX = 0x7B,
	CPU_OP_FEQ = 0x80,
	CPU_OP_FLT = 0x81,
	CPU_OP_FLE = 0x82,
	CPU_OP_FCLASS = 0x83, // rs2 must be zero
	CPU_OP_FTOI = 0x84, // rs2 must be zero
	CPU_OP_FTOU = 0x85, // rs2 must be zero
	CPU_OP_ITOF = 0x86, // rs2 must be zero
	CPU_OP_UTOF = 0x87, // rs2 must be zero

	// bit manipulation (R-format, but RORI)
	CPU_OP_CLZ = 0x90, // rs2 must be zero
	CPU_OP_CTZ = 0x91, // rs2 must be zero
	CPU_OP_POPCNT = 0x92, // rs2 must be zero
	CPU_OP_BSWAP = 0x93, // rs2 must be zero
	CPU_OP_SEXTB = 0x94, // SEXT.B, rs2 must be zero
	CPU_OP_SEXTH = 0x95, // SEXT.H, rs2 must be zero
	CPU_OP_ROL = 0x96,
	CPU_OP_ROR = 0x97,
	CPU_OP_RORI = 0x98, // I-format, zero-extended imm
	CPU_OP_MIN = 0x99,
	CPU_OP_MAX = 0x9A,
	CPU_OP_MINU = 0x9B,
	CPU_OP_MAXU = 0x9C,
} cpu_opcode_t;

typedef enum cpu_format {
	CPU_FORMAT_INVALID = 0,
	CPU_FORMAT_N, // opcode only
	CPU_FORMAT_R,
	CPU_FORMAT_I,
	CPU_FORMAT_U,
} cpu_format_t;

// What the pipeline needs to know about an instruction, worked out once
// when it is decoded
#define CPU_IN_WRITES_RD 0x0001 // has a result for rd (even if rd is r0)
#define CPU_IN_READS_RS1 0x0002
#define CPU_IN_READS_RS2 0x0004
#define CPU_IN_READS_RD 0x0008 // stores, branches, FMADD and FMSUB
#define CPU_IN_RESULT_IN_MEM 0x0010 // rd is produced in MEM: loads, LL, SC
#define CPU_IN_STORE 0x0020 // SB, SH and SW
#define CPU_IN_BRANCH 0x0040
#define CPU_IN_SERIALIZING 0x0080 // MFCR, MTCR and IRET
#define CPU_IN_PRIVILEGED 0x0100 // supervisor only

typedef struct cpu_instruction {
	uint32_t raw;
	uint8_t opcode;
	cpu_format_t format;
	uint8_t rd;
	uint8_t rs1;
	uint8_t rs2;
	uint32_t imm; // already sign/zero extended
	uint16_t flags; // CPU_IN_*
	uint8_t size; // bytes a load or store accesses, 0 for the others
	// cpu_cause_t raised whatever the mode: an illegal instruction,
	// SYSCALL or BREAK; 0 = none
	uint8_t fault;
} cpu_instruction_t;

// Decoded instructions, looked up by their word: decoding is a function
// of the word alone, so nothing ever has to be invalidated.
#define CPU_DECODE_CACHE_SIZE 1024 // a power of 2

// Pipeline register between two stages. !valid = bubble.
typedef struct cpu_latch {
	bool valid;
	uint32_t pc; // address of this instruction
	cpu_instruction_t in; // only in.raw is set in IF/ID
	uint32_t a, b, d; // rs1, rs2, rd source values
	uint32_t result; // ALU result, link address, load address/data
	uint8_t fault; // cpu_cause_t, 0 = no fault, raised when retired in WB
	uint32_t fault_value; // BADADDR
	uint8_t fflags; // SF_FLAG_* of an FP instruction, into FCSR in WB
} cpu_latch_t;

typedef struct cpu_pipeline {
	cpu_latch_t if_id;
	cpu_latch_t id_ex;
	cpu_latch_t ex_mem;
	cpu_latch_t mem_wb;
} cpu_pipeline_t;

// The emulator's own debugging (the monitor), unseen by software: it stops
// the CPU between two instructions, like an interrupt that never enters a
// handler. The ones in flight are squashed and refetched when it goes on,
// so everything before pc has run and nothing after it has.
#define CPU_BREAKPOINT_COUNT 16
#define CPU_WATCHPOINT_COUNT 8

typedef enum cpu_stop {
	CPU_STOP_NONE = 0,
	CPU_STOP_PAUSE, // asked to stop
	CPU_STOP_STEP, // ran the instructions it was asked to
	CPU_STOP_BREAKPOINT, // the next instruction is at a breakpoint
	CPU_STOP_WATCHPOINT, // the last instruction accessed a watched address
} cpu_stop_t;

typedef struct cpu_watchpoint {
	uint32_t address; // virtual
	uint32_t length; // bytes, at least 1
	uint8_t access; // MMU_ACCESS_READ and/or MMU_ACCESS_WRITE
} cpu_watchpoint_t;

typedef struct cpu_debug {
	bool active; // something below is set: checked between instructions
	uint32_t breakpoint[CPU_BREAKPOINT_COUNT]; // virtual addresses
	uint8_t breakpoint_count;
	cpu_watchpoint_t watchpoint[CPU_WATCHPOINT_COUNT];
	uint8_t watchpoint_count;
	bool pause; // stop before the next instruction
	bool stepping; // stop once retired reaches step_target
	uint64_t step_target;
	// After going on from a breakpoint the CPU doesn't stop there again
	// until an instruction has retired.
	bool skip;
	uint32_t skip_pc;
	uint64_t skip_retired;
	// a watchpoint matched; the CPU stops once the access has retired
	bool watch_hit;
	// stopped: nothing runs until cpu_debug_resume
	cpu_stop_t stopped;
	uint32_t hit_pc; // watchpoint: the instruction that accessed
	uint32_t hit_address; // ... the address and what it accessed
	uint8_t hit_access;
} cpu_debug_t;

typedef struct cpu {
	uint32_t gpr[CPU_GPR_COUNT]; // general purpose registers
	uint32_t pc; // fetch address; architectural PC once halted or waiting
	uint32_t cr[CPU_CR_COUNT]; // control registers
	bool halted; // the pipeline is left as it was, for cpu_dump
	uint8_t halt_fault; // cpu_cause_t of the fault that halted it, 0 = HLT
	bool waiting; // WFI: sleeping until the IRQ line is asserted
	bool irq; // IRQ input line, driven by the PIC
	uint64_t cycles; // clock cycles, CYCLE/CYCLEH
	uint64_t retired; // instructions completed in WB, INSTRET/INSTRETH
	bool reservation_valid;
	uint32_t reservation_address; // physical word reserved by LL
	uint8_t trigger_kinds; // CPU_TCTRL_X/R/W of the triggers, OR-ed
	cpu_pipeline_t pipeline;
	cpu_instruction_t decoded[CPU_DECODE_CACHE_SIZE];
	mmu_t* mmu; // translates every fetch, load and store
	bus_t bus; // physical memory
	FILE* trace; // log of retired instructions and traps, NULL = off
	cpu_debug_t debug;
} cpu_t;

cpu_t* cpu_create(const bus_t bus);
void cpu_destroy(cpu_t* cpu);

void cpu_reset(cpu_t* cpu);
void cpu_update(cpu_t* cpu); // advances the pipeline by one clock cycle
// Asleep in WFI with the IRQ line low: that many cycles pass as they would
// one by one with cpu_update.
void cpu_sleep(cpu_t* cpu, const uint64_t cycles);
void cpu_set_irq(cpu_t* cpu, const bool level);
void cpu_invalidate_reservation(cpu_t* cpu, uint32_t physical,
							uint8_t size);

// The emulator's debugging, see cpu_debug_t. Breakpoints and watchpoints
// survive a reset; adding one fails (false) when there is no room.
bool cpu_debug_add_breakpoint(cpu_t* cpu, const uint32_t address);
bool cpu_debug_add_watchpoint(cpu_t* cpu, const uint32_t address,
							  const uint32_t length, const uint8_t access);
// Removes the breakpoints and watchpoints at address; returns how many.
int cpu_debug_remove(cpu_t* cpu, const uint32_t address);
void cpu_debug_remove_all(cpu_t* cpu);
// Stops before the next instruction: at once when halted, at the next
// cycle in WFI.
void cpu_debug_pause(cpu_t* cpu);
// Goes on; with steps > 0 it stops again after that many instructions.
void cpu_debug_resume(cpu_t* cpu, const uint64_t steps);

cpu_instruction_t cpu_decode(const uint32_t raw);
// R-format instructions with a single source, whose rs2 must be zero
bool cpu_rs2_is_reserved(const uint8_t opcode);
const char* cpu_cause_name(const uint8_t cause);

// Prints the registers, control registers, counters and what is in every
// pipeline latch.
void cpu_dump(const cpu_t* cpu, FILE* out);

#endif // WRM_CPU_H
