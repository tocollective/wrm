#ifndef WRM_BUS_H
#define WRM_BUS_H
#include "common.h"

// Memory interface provided by the motherboard.
// size is 1, 2 or 4 bytes; callbacks return true on bus error.
// fetch reads memory (RAM or ROM) only and is a bus error for the I/O
// region: it is used for instruction fetches and page table walks, which
// may be speculative and must never reach a device register.
typedef struct bus {
	void* ctx;
	bool (*read)(void* ctx, const uint32_t address, const uint8_t size,
				 uint32_t* value);
	bool (*fetch)(void* ctx, const uint32_t address, const uint8_t size,
				  uint32_t* value);
	bool (*write)(void* ctx, const uint32_t address, const uint8_t size,
				  const uint32_t value);
} bus_t;

#endif // WRM_BUS_H
