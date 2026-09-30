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

	cpu_update(machine->motherboard->cpu);
}
