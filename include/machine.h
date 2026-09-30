#ifndef WRM_MACHINE_H
#define WRM_MACHINE_H
#include "common.h"

#include "motherboard.h"

typedef struct machine {
	motherboard_t* motherboard;
} machine_t;

machine_t* machine_create(void);
void machine_destroy(machine_t* machine);

void machine_update(machine_t* machine);

#endif // WRM_MACHINE_H
