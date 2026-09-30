#ifndef WRM_POWER_H
#define WRM_POWER_H
#include "common.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define POWER_REG_OFF 0x00 // W: power off, the low 8 bits are the exit code
#define POWER_REG_RESET 0x04 // W: reset the machine, the value is ignored

typedef enum power_request {
	POWER_REQUEST_NONE = 0,
	POWER_REQUEST_OFF,
	POWER_REQUEST_RESET,
} power_request_t;

// Power controller. It only records the request: the motherboard acts on
// it after the current clock tick, so the CPU never resets in the middle
// of a pipeline stage.
typedef struct power {
	power_request_t request;
	uint8_t exit_code; // reported to the host on power off
} power_t;

power_t* power_create(void);
void power_destroy(power_t* power);

void power_reset(power_t* power);

// bus side: offset is relative to the device base; return true on bus error
bool power_read(power_t* power, const uint32_t offset, const uint8_t size,
				uint32_t* value);
bool power_write(power_t* power, const uint32_t offset, const uint8_t size,
				 const uint32_t value);

#endif // WRM_POWER_H
