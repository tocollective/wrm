#ifndef WRM_CPU_H
#define WRM_CPU_H
#include "common.h"

#define CPU_GPR_COUNT 32
#define CPU_GPR_ZERO 0
#define CPU_PC_START 0x1000

typedef struct cpu {
	uint32_t gpr[CPU_GPR_COUNT]; // general purpose registers
	uint32_t pc; // program counter
} cpu_t;

cpu_t* cpu_create(void);
void cpu_destroy(cpu_t* cpu);

void cpu_update(cpu_t* cpu);

#endif // WRM_CPU_H
