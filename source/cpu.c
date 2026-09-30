#include "cpu.h"

cpu_t* cpu_create(void) {
	cpu_t* cpu = (cpu_t*)calloc(1, sizeof(cpu_t));
	if (!cpu) error("Failed to allocate CPU!");
	cpu->gpr[CPU_GPR_ZERO] = 0;
	cpu->pc = CPU_PC_START;
	return cpu;
}

void cpu_destroy(cpu_t* cpu) {
	if (!cpu) return;
	free(cpu);
	cpu = NULL;
}

void cpu_update(cpu_t* cpu) {
}
