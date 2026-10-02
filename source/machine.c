#include "machine.h"

#include "config.h"

machine_t* machine_create(void) {
	const config_t* cfg = config_get();
	machine_t* machine = (machine_t*)calloc(1, sizeof(machine_t));
	if (!machine) error("Failed to allocate the machine!");
	machine->motherboard = motherboard_create();
	if (cfg->input_path) machine->input = input_load(cfg->input_path);

	motherboard_t* mb = machine->motherboard;
	if (cfg->rtc_virtual) rtc_set_virtual(mb->rtc, &mb->tick, cfg->rtc_epoch);
	if (cfg->rng_seeded) rng_set_seed(mb->rng, cfg->rng_seed);
	machine->deterministic = cfg->deterministic;
	machine->net_period = mb->clock->rate / MACHINE_NET_POLLS_PER_SECOND;
	if (machine->net_period == 0) machine->net_period = 1;
	machine->next_poll = machine->net_period;
	return machine;
}

void machine_destroy(machine_t* machine) {
	if (!machine) return;
	if (machine->motherboard) {
		motherboard_destroy(machine->motherboard);
	}
	input_destroy(machine->input);

	free(machine);
	machine = NULL;
}

// The Ethernet card's network keeps its timers in milliseconds of machine
// time.
static void machine_poll_network(machine_t* machine) {
	motherboard_t* mb = machine->motherboard;
	ethcard_poll(mb->ethcard, mb->tick * 1000 / mb->clock->rate);
}

uint64_t machine_run(machine_t* machine, const uint64_t ticks) {
	if (!machine) return 0;
	motherboard_t* mb = machine->motherboard;
	const uint64_t start = machine->ticks;
	const uint64_t end = start + ticks;
	while (machine->ticks < end && !machine_stopped(machine)
		   && !machine_held(machine)) {
		input_feed(machine->input, machine->ticks, mb);
		uint64_t until = end;
		const uint64_t event = input_next_tick(machine->input);
		if (event < until) until = event;
		if (machine->deterministic && machine->next_poll < until)
			until = machine->next_poll;

		machine->ticks += motherboard_run(mb, until - machine->ticks);
		if (machine->deterministic && machine->ticks == machine->next_poll) {
			machine_poll_network(machine);
			machine->next_poll += machine->net_period;
		}
	}
	// the host's network moves between batches of ticks, not every tick
	if (!machine->deterministic) machine_poll_network(machine);
	return machine->ticks - start;
}

void machine_update(machine_t* machine) {
	if (!machine) return;
	machine_run(machine, clock_update(machine->motherboard->clock));
}

void machine_reset(machine_t* machine) {
	if (!machine) return;
	motherboard_reset(machine->motherboard, POWER_RESET_CAUSE_HOST);
}

bool machine_powered_off(const machine_t* machine) {
	return machine->motherboard->power->request == POWER_REQUEST_OFF;
}

bool machine_stopped(const machine_t* machine) {
	return motherboard_stopped(machine->motherboard);
}

bool machine_held(const machine_t* machine) {
	return machine->motherboard->cpu->debug.stopped != CPU_STOP_NONE;
}
