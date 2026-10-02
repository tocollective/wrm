#include "devices/watchdog.h"

static void watchdog_update_irq(watchdog_t* watchdog) {
	pic_set_line(watchdog->pic, watchdog->irq, watchdog->bark);
}

watchdog_t* watchdog_create(pic_t* pic, const uint8_t irq) {
	watchdog_t* watchdog = (watchdog_t*)calloc(1, sizeof(watchdog_t));
	if (!watchdog) error("Failed to allocate the watchdog!");
	watchdog->pic = pic;
	watchdog->irq = irq;
	watchdog_reset(watchdog);
	return watchdog;
}

void watchdog_destroy(watchdog_t* watchdog) {
	if (!watchdog) return;
	free(watchdog);
	watchdog = NULL;
}

void watchdog_reset(watchdog_t* watchdog) {
	if (!watchdog) return;
	watchdog->control = 0;
	watchdog->timeout = 0;
	watchdog->grace = 0;
	watchdog->value = 0;
	watchdog->barked = false;
	watchdog->bark = false;
	watchdog->bitten = false;
	watchdog_update_irq(watchdog);
}

static bool watchdog_enabled(const watchdog_t* watchdog) {
	return (watchdog->control & WATCHDOG_CONTROL_ENABLE) && !watchdog->bitten;
}

// The first stage again, from TIMEOUT (0 counts as 1).
static void watchdog_restart(watchdog_t* watchdog) {
	watchdog->value = watchdog->timeout > 0 ? watchdog->timeout : 1;
	watchdog->barked = false;
}

// While enabled, VALUE goes down every tick; on the tick it reaches 0 the
// stage ends: the first one barks and starts GRACE, the second one bites.
void watchdog_run(watchdog_t* watchdog, uint64_t ticks) {
	while (ticks > 0 && watchdog_enabled(watchdog)) {
		if (ticks < watchdog->value) {
			watchdog->value -= (uint32_t)ticks;
			return;
		}
		ticks -= watchdog->value;
		if (watchdog->barked) {
			watchdog->value = 0;
			watchdog->bitten = true;
			return;
		}
		watchdog->barked = true;
		watchdog->bark = true;
		watchdog->value = watchdog->grace > 0 ? watchdog->grace : 1;
		watchdog_update_irq(watchdog);
	}
}

uint64_t watchdog_next_event(const watchdog_t* watchdog) {
	if (!watchdog_enabled(watchdog)) return TICKS_NEVER;
	return watchdog->value > 0 ? watchdog->value : 1;
}

bool watchdog_read(watchdog_t* watchdog, const uint32_t offset,
				   const uint8_t size, uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case WATCHDOG_REG_CONTROL:
			*value = watchdog->control;
			return false;
		case WATCHDOG_REG_TIMEOUT:
			*value = watchdog->timeout;
			return false;
		case WATCHDOG_REG_GRACE:
			*value = watchdog->grace;
			return false;
		case WATCHDOG_REG_KICK:
			*value = 0; // write-only
			return false;
		case WATCHDOG_REG_VALUE:
			*value = watchdog->value;
			return false;
		case WATCHDOG_REG_STATUS:
			*value = (watchdog->bark ? WATCHDOG_STATUS_BARK : 0)
				   | (watchdog->barked && watchdog_enabled(watchdog)
						  ? WATCHDOG_STATUS_GRACE
						  : 0);
			return false;
	}
	return true;
}

bool watchdog_write(watchdog_t* watchdog, const uint32_t offset,
					const uint8_t size, const uint32_t value) {
	(void)size;
	const bool locked = watchdog->control & WATCHDOG_CONTROL_LOCK;
	switch (offset) {
		case WATCHDOG_REG_CONTROL: {
			if (locked) return false;
			const bool was_enabled = watchdog_enabled(watchdog);
			watchdog->control = value & WATCHDOG_CONTROL_MASK;
			// turning it on starts the first stage, turning it off stops
			// it where it is
			if (!was_enabled && watchdog_enabled(watchdog))
				watchdog_restart(watchdog);
			return false;
		}
		case WATCHDOG_REG_TIMEOUT:
			if (!locked) watchdog->timeout = value;
			return false;
		case WATCHDOG_REG_GRACE:
			if (!locked) watchdog->grace = value;
			return false;
		case WATCHDOG_REG_KICK:
			if (watchdog_enabled(watchdog)) {
				watchdog_restart(watchdog);
				watchdog->bark = false;
				watchdog_update_irq(watchdog);
			}
			return false;
		case WATCHDOG_REG_VALUE:
			return false; // read-only
		case WATCHDOG_REG_STATUS:
			if (value & WATCHDOG_STATUS_BARK) {
				watchdog->bark = false;
				watchdog_update_irq(watchdog);
			}
			return false;
	}
	return true;
}
