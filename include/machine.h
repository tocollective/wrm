#ifndef WRM_MACHINE_H
#define WRM_MACHINE_H
#include "common.h"

#include "input.h"
#include "motherboard.h"

// Network polls per second of machine time in deterministic mode
#define MACHINE_NET_POLLS_PER_SECOND 1000

typedef struct machine {
	motherboard_t* motherboard;
	uint64_t ticks; // clock ticks run, across resets: for the speed shown
	input_t* input; // --input, NULL = none
	// Deterministic mode polls the network every net_period ticks, at
	// next_poll; otherwise after every batch of ticks.
	bool deterministic;
	uint64_t net_period;
	uint64_t next_poll;
} machine_t;

machine_t* machine_create(void);
void machine_destroy(machine_t* machine);

// Runs as many ticks as the clock says have passed in host time.
void machine_update(machine_t* machine);
// Runs that many ticks, or until the machine stops; returns the ticks run.
// The input script and the network are fed between them.
uint64_t machine_run(machine_t* machine, const uint64_t ticks);
// The host's reset key: a reset like the power controller's RESET, also
// after the CPU has halted.
void machine_reset(machine_t* machine);

// The guest turned the machine off through the power controller.
bool machine_powered_off(const machine_t* machine);
// Nothing will run any more: powered off, or the CPU is halted.
bool machine_stopped(const machine_t* machine);
// The debugger has stopped the CPU: nothing runs until it goes on.
bool machine_held(const machine_t* machine);

#endif // WRM_MACHINE_H
