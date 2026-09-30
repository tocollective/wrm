#include "devices/power.h"

power_t* power_create(void) {
	power_t* power = (power_t*)calloc(1, sizeof(power_t));
	if (!power) error("Failed to allocate power controller!");
	power_reset(power);
	return power;
}

void power_destroy(power_t* power) {
	if (!power) return;
	free(power);
	power = NULL;
}

void power_reset(power_t* power) {
	if (!power) return;
	power->request = POWER_REQUEST_NONE;
	power->exit_code = 0;
}

bool power_read(power_t* power, const uint32_t offset, const uint8_t size,
				uint32_t* value) {
	(void)power;
	(void)size;
	switch (offset) {
		case POWER_REG_OFF:
		case POWER_REG_RESET:
			*value = 0; // write-only
			return false;
	}
	return true;
}

bool power_write(power_t* power, const uint32_t offset, const uint8_t size,
				 const uint32_t value) {
	(void)size;
	// the first request wins: nothing runs after it anyway
	switch (offset) {
		case POWER_REG_OFF:
			if (power->request == POWER_REQUEST_NONE) {
				power->request = POWER_REQUEST_OFF;
				power->exit_code = value & 0xFF;
			}
			return false;
		case POWER_REG_RESET:
			if (power->request == POWER_REQUEST_NONE)
				power->request = POWER_REQUEST_RESET;
			return false;
	}
	return true;
}
