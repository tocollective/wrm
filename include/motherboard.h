#ifndef WRM_MOTHERBOARD_H
#define WRM_MOTHERBOARD_H
#include "common.h"

#include "cpu.h"
#include "ram.h"
#include "rom.h"

#define RAM_SLOT_COUNT 4

typedef struct ram_slot {
	ram_t* ram;
	bool installed;
} ram_slot_t;

typedef struct motherboard {
	cpu_t* cpu;
	ram_slot_t ram_slot[RAM_SLOT_COUNT];
	rom_t* rom;
} motherboard_t;

motherboard_t* motherboard_create(void);
void motherboard_destroy(motherboard_t* mb);

#endif // WRM_MOTHERBOARD_H
