#include "devices/audiocard.h"

#include <string.h>

#define AUDIO_VOICE_BITS ((1u << AUDIO_VOICE_COUNT) - 1)

static void audiocard_update_irq(audiocard_t* card) {
	pic_set_line(card->pic, card->irq, card->status != 0);
}

audiocard_t* audiocard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
							  const uint32_t clock_rate) {
	audiocard_t* card = (audiocard_t*)calloc(1, sizeof(audiocard_t));
	if (!card) error("Failed to allocate audio card!");
	card->pic = pic;
	card->irq = irq;
	card->dma = dma;
	card->clock_rate = clock_rate;
	audiocard_reset(card);
	return card;
}

void audiocard_destroy(audiocard_t* card) {
	if (!card) return;
	free(card);
	card = NULL;
}

void audiocard_reset(audiocard_t* card) {
	if (!card) return;
	card->status = 0;
	card->fault = 0;
	card->master = 0;
	memset(card->voice, 0, sizeof(card->voice));
	// the output keeps going: frames already made still get played
	audiocard_update_irq(card);
}

// A sample value as a 16-bit one: raw is a byte, or a half-word if wide.
static int32_t audiocard_value(const uint32_t raw, const bool wide) {
	if (wide) return (int32_t)((raw & 0xFFFF) ^ 0x8000) - 0x8000;
	return ((int32_t)((raw & 0xFF) ^ 0x80) - 0x80) * 256;
}

// Reads the frame at POSITION; false if the DMA can't.
static bool audiocard_fetch(audiocard_t* card, const audio_voice_t* voice,
							int32_t* left, int32_t* right) {
	const bool wide = voice->control & AUDIO_CONTROL_16BIT;
	const bool stereo = voice->control & AUDIO_CONTROL_STEREO;
	const uint8_t bytes = wide ? 2 : 1;
	const uint32_t frame = (uint32_t)(voice->position >> 32);
	const uint32_t address =
		voice->address + frame * bytes * (stereo ? 2u : 1u);
	if (address & (bytes - 1)) return false;

	uint32_t l = 0;
	uint32_t r = 0;
	if (card->dma.read(card->dma.ctx, address, bytes, &l)) return false;
	if (!stereo)
		r = l;
	else if (card->dma.read(card->dma.ctx, address + bytes, bytes, &r))
		return false;
	*left = audiocard_value(l, wide);
	*right = audiocard_value(r, wide);
	return true;
}

// The voice is at its end or past it: it loops back below LENGTH, or
// stops at LENGTH.
static void audiocard_voice_end(audiocard_t* card, const int n) {
	audio_voice_t* voice = &card->voice[n];
	const uint64_t length = (uint64_t)voice->length << 32;
	if ((voice->control & AUDIO_CONTROL_LOOP) && voice->loop < voice->length) {
		const uint64_t loop = (uint64_t)voice->loop << 32;
		voice->position = loop + (voice->position - length) % (length - loop);
	} else {
		voice->control &= ~AUDIO_CONTROL_ON;
		voice->position = length;
	}
	if (voice->control & AUDIO_CONTROL_SIGNAL_END) card->status |= 1u << n;
}

// Scales a sample value by a volume of 0-255.
static int32_t audiocard_scale(const int32_t value, const uint32_t volume) {
	return value * (int32_t)(volume & 0xFF) / 255;
}

static int16_t audiocard_clip(const int32_t value) {
	if (value < INT16_MIN) return INT16_MIN;
	if (value > INT16_MAX) return INT16_MAX;
	return (int16_t)value;
}

// Plays one output frame of every voice and mixes them.
static void audiocard_frame(audiocard_t* card) {
	const uint32_t status = card->status;
	int32_t left = 0;
	int32_t right = 0;
	for (int n = 0; n < AUDIO_VOICE_COUNT; n++) {
		audio_voice_t* voice = &card->voice[n];
		if (!(voice->control & AUDIO_CONTROL_ON)) continue;
		const uint64_t length = (uint64_t)voice->length << 32;
		// turned on at its end: that end comes before anything plays
		if (voice->position >= length) {
			audiocard_voice_end(card, n);
			if (!(voice->control & AUDIO_CONTROL_ON)) continue;
		}

		int32_t l = 0;
		int32_t r = 0;
		if (!audiocard_fetch(card, voice, &l, &r)) {
			voice->control &= ~AUDIO_CONTROL_ON;
			card->fault |= 1u << n;
			continue;
		}
		left += audiocard_scale(l, voice->volume);
		right += audiocard_scale(r, voice->volume >> 8);

		const uint64_t half = (uint64_t)(voice->length / 2) << 32;
		const uint64_t old = voice->position;
		voice->position = old + voice->step;
		if (voice->position < old) voice->position = UINT64_MAX;
		if (old < half && voice->position >= half
			&& (voice->control & AUDIO_CONTROL_SIGNAL_HALF))
			card->status |= 1u << n;
		if (voice->position >= length) audiocard_voice_end(card, n);
	}
	if (card->status != status) audiocard_update_irq(card);

	// a full buffer drops the frame: the host isn't keeping up
	if (!card->connected || card->frame_count >= AUDIO_BUFFER_FRAMES) return;
	int16_t* out = &card->frames[card->frame_count * 2];
	out[0] = audiocard_clip(audiocard_scale(left, card->master));
	out[1] = audiocard_clip(audiocard_scale(right, card->master >> 8));
	card->frame_count++;
}

// Every tick sample_clock goes up by the sample rate, and each time it
// reaches the clock rate a frame is played.
static uint64_t audiocard_frame_due(const audiocard_t* card) {
	return (card->clock_rate - card->sample_clock + AUDIO_SAMPLE_RATE - 1)
		 / AUDIO_SAMPLE_RATE;
}

static bool audiocard_playing(const audiocard_t* card) {
	for (int n = 0; n < AUDIO_VOICE_COUNT; n++)
		if (card->voice[n].control & AUDIO_CONTROL_ON) return true;
	return false;
}

void audiocard_run(audiocard_t* card, uint64_t ticks) {
	// silent frames nobody hears do nothing at all
	if (!card->connected && !audiocard_playing(card)) {
		card->sample_clock = (card->sample_clock
							  + ticks % card->clock_rate * AUDIO_SAMPLE_RATE)
						   % card->clock_rate;
		return;
	}
	while (ticks > 0) {
		const uint64_t due = audiocard_frame_due(card);
		if (ticks < due) {
			card->sample_clock += ticks * AUDIO_SAMPLE_RATE;
			return;
		}
		ticks -= due;
		card->sample_clock += due * AUDIO_SAMPLE_RATE;
		// more than once per tick only with a clock below the sample rate
		while (card->sample_clock >= card->clock_rate) {
			card->sample_clock -= card->clock_rate;
			audiocard_frame(card);
		}
	}
}

uint64_t audiocard_next_event(const audiocard_t* card) {
	return audiocard_playing(card) ? audiocard_frame_due(card) : TICKS_NEVER;
}

// The voice that offset falls in, with offset made relative to it; NULL
// if it is outside the voices.
static audio_voice_t*
audiocard_find_voice(audiocard_t* card, const uint32_t offset, uint32_t* reg) {
	if (offset < AUDIO_REG_VOICE0) return NULL;
	const uint32_t index = (offset - AUDIO_REG_VOICE0) / AUDIO_VOICE_SIZE;
	if (index >= AUDIO_VOICE_COUNT) return NULL;
	*reg = (offset - AUDIO_REG_VOICE0) % AUDIO_VOICE_SIZE;
	return &card->voice[index];
}

static bool audiocard_voice_read(const audio_voice_t* voice, const uint32_t reg,
								 uint32_t* value) {
	switch (reg) {
		case AUDIO_VOICE_CONTROL:
			*value = voice->control;
			return false;
		case AUDIO_VOICE_ADDRESS:
			*value = voice->address;
			return false;
		case AUDIO_VOICE_LENGTH:
			*value = voice->length;
			return false;
		case AUDIO_VOICE_LOOP:
			*value = voice->loop;
			return false;
		case AUDIO_VOICE_POSITION:
			*value = (uint32_t)(voice->position >> 32);
			return false;
		case AUDIO_VOICE_RATE:
			*value = voice->rate;
			return false;
		case AUDIO_VOICE_VOLUME:
			*value = voice->volume;
			return false;
	}
	return true;
}

static bool audiocard_voice_write(audio_voice_t* voice, const uint32_t reg,
								  const uint32_t value) {
	switch (reg) {
		case AUDIO_VOICE_CONTROL:
			voice->control = value & AUDIO_CONTROL_MASK;
			return false;
		case AUDIO_VOICE_ADDRESS:
			voice->address = value;
			return false;
		case AUDIO_VOICE_LENGTH:
			voice->length = value;
			return false;
		case AUDIO_VOICE_LOOP:
			voice->loop = value;
			return false;
		case AUDIO_VOICE_POSITION:
			// the fraction is dropped
			voice->position = (uint64_t)value << 32;
			return false;
		case AUDIO_VOICE_RATE:
			voice->rate = value & AUDIO_RATE_MASK;
			voice->step = ((uint64_t)voice->rate << 32) / AUDIO_SAMPLE_RATE;
			return false;
		case AUDIO_VOICE_VOLUME:
			voice->volume = value & AUDIO_VOLUME_MASK;
			return false;
	}
	return true;
}

bool audiocard_read(audiocard_t* card, const uint32_t offset,
					const uint8_t size, uint32_t* value) {
	(void)size; // narrower loads get the low bits
	uint32_t reg = 0;
	const audio_voice_t* voice = audiocard_find_voice(card, offset, &reg);
	if (voice) return audiocard_voice_read(voice, reg, value);
	switch (offset) {
		case AUDIO_REG_STATUS:
			*value = card->status;
			return false;
		case AUDIO_REG_FAULT:
			*value = card->fault;
			return false;
		case AUDIO_REG_MASTER:
			*value = card->master;
			return false;
		case AUDIO_REG_VOICES:
			*value = AUDIO_VOICE_COUNT;
			return false;
		case AUDIO_REG_RATE:
			*value = AUDIO_SAMPLE_RATE;
			return false;
	}
	return true;
}

bool audiocard_write(audiocard_t* card, const uint32_t offset,
					 const uint8_t size, const uint32_t value) {
	(void)size;
	uint32_t reg = 0;
	audio_voice_t* voice = audiocard_find_voice(card, offset, &reg);
	if (voice) return audiocard_voice_write(voice, reg, value);
	switch (offset) {
		case AUDIO_REG_STATUS:
			card->status &= ~(value & AUDIO_VOICE_BITS);
			audiocard_update_irq(card);
			return false;
		case AUDIO_REG_FAULT:
			card->fault &= ~(value & AUDIO_VOICE_BITS);
			return false;
		case AUDIO_REG_MASTER:
			card->master = value & AUDIO_VOLUME_MASK;
			return false;
		case AUDIO_REG_VOICES:
		case AUDIO_REG_RATE:
			return false; // read-only, writes are ignored
	}
	return true;
}
