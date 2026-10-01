#ifndef WRM_BEEPER_H
#define WRM_BEEPER_H
#include "common.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define BEEPER_REG_CONTROL 0x00 // RW
#define BEEPER_REG_FREQUENCY 0x04 // RW: tone in Hz, 0 = silence
#define BEEPER_REG_DURATION 0x08 // RW: ticks left to sound, 0 = untimed

#define BEEPER_CONTROL_ON 0x01
#define BEEPER_CONTROL_MASK BEEPER_CONTROL_ON

// Output for the host: mono signed 16-bit samples at this rate
#define BEEPER_SAMPLE_RATE 48000
// Samples kept between two drains by the host: 100ms, the most host time
// a single clock update turns into ticks (CLOCK_MAX_ELAPSED_NS)
#define BEEPER_BUFFER_SIZE (BEEPER_SAMPLE_RATE / 10)
#define BEEPER_AMPLITUDE 6000 // of 32767: a beeper, not a sound card

// One-voice square wave generator, like the PC speaker. The wave is
// sampled every clock tick and averaged over each output sample, which
// keeps high tones from aliasing too badly.
typedef struct beeper {
	uint32_t clock_rate;
	uint32_t control;
	uint32_t frequency;
	uint32_t duration;

	uint32_t phase; // of the wave, a full turn is 2^32
	uint32_t step; // phase advance per tick

	// output, only made while connected to the host's speaker
	bool connected;
	uint64_t sample_clock; // goes up by SAMPLE_RATE per tick, wraps at the clock rate
	int32_t level_sum; // +1/-1/0 per tick of the current sample
	uint32_t level_ticks;
	int16_t last_sample;
	int16_t samples[BEEPER_BUFFER_SIZE];
	uint32_t sample_count; // the host takes them and lowers this
} beeper_t;

beeper_t* beeper_create(const uint32_t clock_rate);
void beeper_destroy(beeper_t* beeper);

void beeper_reset(beeper_t* beeper);
// advances the beeper by one clock tick
void beeper_tick(beeper_t* beeper);

// bus side: offset is relative to the device base; return true on bus error
bool beeper_read(beeper_t* beeper, const uint32_t offset, const uint8_t size,
				 uint32_t* value);
bool beeper_write(beeper_t* beeper, const uint32_t offset, const uint8_t size,
				  const uint32_t value);

#endif // WRM_BEEPER_H
