#include "devices/power.h"

static void power_update_irq(power_t* power) {
	pic_set_line(power->pic, power->irq, power->status != 0);
}

power_t* power_create(pic_t* pic, const uint8_t irq) {
	power_t* power = (power_t*)calloc(1, sizeof(power_t));
	if (!power) error("Failed to allocate power controller!");
	power->pic = pic;
	power->irq = irq;
	power_reset(power, POWER_RESET_CAUSE_POWER_ON);
	return power;
}

void power_destroy(power_t* power) {
	if (!power) return;
	free(power);
	power = NULL;
}

void power_reset(power_t* power, const power_reset_cause_t cause) {
	if (!power) return;
	power->request = POWER_REQUEST_NONE;
	power->exit_code = 0;
	power->status = 0;
	power->reset_cause = cause;
	power_update_irq(power);
}

void power_request_off(power_t* power) {
	if (!power) return;
	power->status |= POWER_STATUS_OFF_REQUEST;
	power_update_irq(power);
}

bool power_read(power_t* power, const uint32_t offset, const uint8_t size,
				uint32_t* value) {
	(void)size;
	switch (offset) {
		case POWER_REG_OFF:
		case POWER_REG_RESET:
			*value = 0; // write-only
			return false;
		case POWER_REG_STATUS:
			*value = power->status;
			return false;
		case POWER_REG_RESET_CAUSE:
			*value = power->reset_cause;
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
		case POWER_REG_STATUS:
			power->status &= ~value;
			power_update_irq(power);
			return false;
		case POWER_REG_RESET_CAUSE:
			return false; // read-only
	}
	return true;
}
