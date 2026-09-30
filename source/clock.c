#include "clock.h"

#include <SDL3/SDL_timer.h>

sys_clock_t* clock_create(const uint64_t rate) {
	if (rate == 0) error("Failed to create clock: %s", "rate is zero!");

	sys_clock_t* clock = (sys_clock_t*)calloc(1, sizeof(sys_clock_t));
	if (!clock) error("Failed to allocate clock!");
	clock->rate = rate;
	clock_reset(clock);
	return clock;
}

void clock_destroy(sys_clock_t* clock) {
	if (!clock) return;
	free(clock);
	clock = NULL;
}

void clock_reset(sys_clock_t* clock) {
	if (!clock) return;
	clock->ticks = 0;
	clock->last_ns = SDL_GetTicksNS();
	clock->remainder = 0;
}

uint64_t clock_update(sys_clock_t* clock) {
	if (!clock) return 0;

	const uint64_t now = SDL_GetTicksNS();
	uint64_t elapsed = now - clock->last_ns;
	clock->last_ns = now;
	if (elapsed > CLOCK_MAX_ELAPSED_NS) {
		elapsed = CLOCK_MAX_ELAPSED_NS;
		clock->remainder = 0;
	}

	// elapsed is capped, so this fits in 64 bits for rates up to ~184 GHz
	const uint64_t total = elapsed * clock->rate + clock->remainder;
	const uint64_t ticks = total / CLOCK_NS_PER_SECOND;
	clock->remainder = total % CLOCK_NS_PER_SECOND;
	clock->ticks += ticks;
	return ticks;
}
