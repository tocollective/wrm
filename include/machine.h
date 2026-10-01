#ifndef WRM_MACHINE_H
#define WRM_MACHINE_H
#include "common.h"

#include "motherboard.h"

typedef struct machine {
	motherboard_t* motherboard;
	uint64_t ticks; // clock ticks run, across resets: for the speed shown
} machine_t;

machine_t* machine_create(void);
void machine_destroy(machine_t* machine);

void machine_update(machine_t* machine);
// The host's reset key: a reset like the power controller's RESET, also
// after the CPU has halted.
void machine_reset(machine_t* machine);

// The guest turned the machine off through the power controller.
bool machine_powered_off(const machine_t* machine);
// Nothing will run any more: powered off, or the CPU is halted.
bool machine_stopped(const machine_t* machine);

#endif // WRM_MACHINE_H
