#ifndef WRM_POWER_H
#define WRM_POWER_H
#include "common.h"

#include "devices/pic.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define POWER_REG_OFF 0x00 // W: power off, the low 8 bits are the exit code
#define POWER_REG_RESET 0x04 // W: reset the machine, the value is ignored
#define POWER_REG_STATUS 0x08 // R, W: 1 clears the bit
#define POWER_REG_RESET_CAUSE 0x0C // R: why the machine last started

#define POWER_STATUS_OFF_REQUEST 0x01 // the host asks to power off

typedef enum power_request {
	POWER_REQUEST_NONE = 0,
	POWER_REQUEST_OFF,
	POWER_REQUEST_RESET,
} power_request_t;

// RESET_CAUSE values
typedef enum power_reset_cause {
	POWER_RESET_CAUSE_POWER_ON = 0,
	POWER_RESET_CAUSE_SOFTWARE = 1, // a write to RESET
	POWER_RESET_CAUSE_HOST = 2, // the host's reset key
	// 3 is reserved for a reset by a double fault
} power_reset_cause_t;

// Power controller. It only records the request: the motherboard acts on
// it after the current clock tick, so the CPU never resets in the middle
// of a pipeline stage. The host's request to power off (the window is
// closed) is passed on to software, which asserts the IRQ line until
// software clears it.
typedef struct power {
	pic_t* pic;
	uint8_t irq;
	power_request_t request;
	uint8_t exit_code; // reported to the host on power off
	uint32_t status;
	power_reset_cause_t reset_cause;
} power_t;

power_t* power_create(pic_t* pic, const uint8_t irq);
void power_destroy(power_t* power);

// cause: why the machine starts again, kept in RESET_CAUSE
void power_reset(power_t* power, const power_reset_cause_t cause);
// host side: asks software to power the machine off
void power_request_off(power_t* power);

// bus side: offset is relative to the device base; return true on bus error
bool power_read(power_t* power, const uint32_t offset, const uint8_t size,
				uint32_t* value);
bool power_write(power_t* power, const uint32_t offset, const uint8_t size,
				 const uint32_t value);

#endif // WRM_POWER_H
