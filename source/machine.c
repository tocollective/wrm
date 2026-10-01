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
	for (uint64_t i = 0; i < ticks && !machine_stopped(machine); i++) {
		motherboard_tick(mb);
		machine->ticks++;
	}
	// the host's network moves between batches of ticks, not every tick
	netcard_poll(mb->netcard);
}

void machine_reset(machine_t* machine) {
	if (!machine) return;
	motherboard_reset(machine->motherboard, POWER_RESET_CAUSE_HOST);
}

bool machine_powered_off(const machine_t* machine) {
	return machine->motherboard->power->request == POWER_REQUEST_OFF;
}

bool machine_stopped(const machine_t* machine) {
	return machine->motherboard->cpu->halted || machine_powered_off(machine);
}
