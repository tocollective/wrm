#include "devices/beeper.h"

beeper_t* beeper_create(const uint32_t clock_rate) {
	beeper_t* beeper = (beeper_t*)calloc(1, sizeof(beeper_t));
	if (!beeper) error("Failed to allocate beeper!");
	beeper->clock_rate = clock_rate;
	beeper_reset(beeper);
	return beeper;
}

void beeper_destroy(beeper_t* beeper) {
	if (!beeper) return;
	free(beeper);
	beeper = NULL;
}

void beeper_reset(beeper_t* beeper) {
	if (!beeper) return;
	beeper->control = 0;
	beeper->frequency = 0;
	beeper->duration = 0;
	beeper->phase = 0;
	beeper->step = 0;
	// the output keeps going: samples already made still get played
}

// Phase advance per tick for FREQUENCY. A tone above half the clock rate
// can't be made at all, so it is silence.
static uint32_t beeper_step(const beeper_t* beeper) {
	if ((uint64_t)beeper->frequency * 2 > beeper->clock_rate) return 0;
	return (uint32_t)(((uint64_t)beeper->frequency << 32) / beeper->clock_rate);
}

// Emits the samples that are due. A full buffer drops them: the host
// isn't keeping up.
static void beeper_emit(beeper_t* beeper) {
	// more than once per tick only with a clock below the sample rate
	while (beeper->sample_clock >= beeper->clock_rate) {
		beeper->sample_clock -= beeper->clock_rate;
		if (beeper->level_ticks) {
			const int64_t sum = beeper->level_sum;
			beeper->last_sample =
				(int16_t)(sum * BEEPER_AMPLITUDE / beeper->level_ticks);
			beeper->level_sum = 0;
			beeper->level_ticks = 0;
		}
		if (beeper->sample_count < BEEPER_BUFFER_SIZE)
			beeper->samples[beeper->sample_count++] = beeper->last_sample;
	}
}

// Adds the level of this tick to the current sample.
static void beeper_sample(beeper_t* beeper, const int32_t level) {
	beeper->level_sum += level;
	beeper->level_ticks++;
	beeper->sample_clock += BEEPER_SAMPLE_RATE;
	beeper_emit(beeper);
}

// Ticks of silence, a sample at a time.
static void beeper_silence(beeper_t* beeper, uint64_t ticks) {
	while (ticks > 0) {
		// ticks up to the one that emits the next sample, at least 1
		const uint64_t due =
			(beeper->clock_rate - beeper->sample_clock + BEEPER_SAMPLE_RATE - 1)
			/ BEEPER_SAMPLE_RATE;
		const uint64_t n = ticks < due ? ticks : due;
		beeper->level_ticks += (uint32_t)n;
		beeper->sample_clock += n * BEEPER_SAMPLE_RATE;
		ticks -= n;
		beeper_emit(beeper);
	}
}

static void beeper_tick(beeper_t* beeper) {
	const bool on = beeper->control & BEEPER_CONTROL_ON;
	int32_t level = 0;
	if (on && beeper->step) {
		level = beeper->phase < 0x80000000u ? 1 : -1;
		beeper->phase += beeper->step;
	}
	// DURATION = N sounds for exactly N ticks
	if (on && beeper->duration && --beeper->duration == 0)
		beeper->control &= ~BEEPER_CONTROL_ON;
	if (beeper->connected) beeper_sample(beeper, level);
}

void beeper_run(beeper_t* beeper, uint64_t ticks) {
	// a tone the host hears is sampled tick by tick
	for (; ticks > 0 && beeper->connected
		   && (beeper->control & BEEPER_CONTROL_ON);
		 ticks--)
		beeper_tick(beeper);
	if (ticks == 0) return;

	if (beeper->control & BEEPER_CONTROL_ON) { // nobody hears it
		uint64_t sounding = ticks;
		if (beeper->duration && beeper->duration < sounding)
			sounding = beeper->duration;
		beeper->phase += (uint32_t)(beeper->step * sounding);
		if (beeper->duration) {
			beeper->duration -= (uint32_t)sounding;
			if (beeper->duration == 0) beeper->control &= ~BEEPER_CONTROL_ON;
		}
	} else if (beeper->connected) {
		beeper_silence(beeper, ticks);
	}
}

bool beeper_read(beeper_t* beeper, const uint32_t offset, const uint8_t size,
				 uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case BEEPER_REG_CONTROL:
			*value = beeper->control;
			return false;
		case BEEPER_REG_FREQUENCY:
			*value = beeper->frequency;
			return false;
		case BEEPER_REG_DURATION:
			*value = beeper->duration;
			return false;
	}
	return true;
}

bool beeper_write(beeper_t* beeper, const uint32_t offset, const uint8_t size,
				  const uint32_t value) {
	(void)size;
	switch (offset) {
		case BEEPER_REG_CONTROL: {
			const uint32_t control = value & BEEPER_CONTROL_MASK;
			// every tone starts at the beginning of the wave
			if ((control & BEEPER_CONTROL_ON)
				&& !(beeper->control & BEEPER_CONTROL_ON))
				beeper->phase = 0;
			beeper->control = control;
			return false;
		}
		case BEEPER_REG_FREQUENCY:
			beeper->frequency = value;
			beeper->step = beeper_step(beeper);
			return false;
		case BEEPER_REG_DURATION:
			beeper->duration = value;
			return false;
	}
	return true;
}
