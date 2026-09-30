#ifndef WRM_CLOCK_H
#define WRM_CLOCK_H
#include "common.h"

// Max host time turned into ticks per update, so a stall on the host
// (breakpoint, window drag) doesn't make the machine catch up in a burst.
#define CLOCK_MAX_ELAPSED_NS 100000000ULL // 100ms

#define CLOCK_NS_PER_SECOND 1000000000ULL

// System clock: turns host time into machine clock ticks.
// Named sys_clock_t because clock_t is taken by <time.h>/<sys/types.h>.
typedef struct clock {
	uint64_t rate; // Hz
	uint64_t ticks; // total ticks produced
	uint64_t last_ns; // host time of the previous update
	uint64_t remainder; // fraction of a tick left over, in ns * rate
} sys_clock_t;

sys_clock_t* clock_create(const uint64_t rate);
void clock_destroy(sys_clock_t* clock);

void clock_reset(sys_clock_t* clock);
// returns ticks due since the last update
uint64_t clock_update(sys_clock_t* clock);

#endif // WRM_CLOCK_H
