#ifndef WRM_BUS_H
#define WRM_BUS_H
#include "common.h"

// Memory interface provided by the motherboard.
// size is 1, 2 or 4 bytes; callbacks return true on bus error.
typedef struct bus {
	void* ctx;
	bool (*read)(void* ctx, const uint32_t address, const uint8_t size,
				 uint32_t* value);
	bool (*write)(void* ctx, const uint32_t address, const uint8_t size,
				  const uint32_t value);
} bus_t;

#endif // WRM_BUS_H
