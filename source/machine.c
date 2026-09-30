#include "machine.h"

machine_t* machine_create(void) {
	machine_t* machine = (machine_t*)calloc(1, sizeof(machine_t));
	machine->motherboard = motherboard_create();
	return machine;
}

void machine_destroy(machine_t* machine) {
	if (!machine) return;
	if (machine->motherboard) {
		motherboard_destroy(machine->motherboard);
	}

	free(machine);
	machine = NULL;
}

void machine_update(machine_t* machine) {
	if (!machine) return;

	motherboard_t* mb = machine->motherboard;
	const uint64_t ticks = clock_update(mb->clock);
	for (uint64_t i = 0; i < ticks && !mb->cpu->halted; i++) {
		cpu_update(mb->cpu);
	}
}
