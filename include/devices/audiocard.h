#ifndef WRM_AUDIOCARD_H
#define WRM_AUDIOCARD_H
#include "common.h"

#include "bus.h"
#include "devices/pic.h"

#define AUDIO_VOICE_COUNT 8
// Output for the host: stereo signed 16-bit frames at this rate, the
// beeper's rate, so the two can be mixed frame by frame
#define AUDIO_SAMPLE_RATE 48000
// Frames kept between two drains by the host: 100ms, the most host time
// a single clock update turns into ticks (CLOCK_MAX_ELAPSED_NS)
#define AUDIO_BUFFER_FRAMES (AUDIO_SAMPLE_RATE / 10)
#define AUDIO_RATE_MASK 0x00FFFFFF // RATE keeps its low 24 bits

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define AUDIO_REG_STATUS 0x00 // RW: voices that signalled, W 1 clears
#define AUDIO_REG_FAULT 0x04 // RW: voices stopped by DMA, W 1 clears
#define AUDIO_REG_MASTER 0x08 // RW: bits 0-7 left, 8-15 right
#define AUDIO_REG_VOICES 0x0C // R: AUDIO_VOICE_COUNT
#define AUDIO_REG_RATE 0x10 // R: AUDIO_SAMPLE_RATE
#define AUDIO_REG_VOICE0 0x100 // voice N at VOICE0 + N * VOICE_SIZE
#define AUDIO_VOICE_SIZE 0x20

// Voice registers (offsets from the voice's base)
#define AUDIO_VOICE_CONTROL 0x00 // RW
#define AUDIO_VOICE_ADDRESS 0x04 // RW: physical address of frame 0
#define AUDIO_VOICE_LENGTH 0x08 // RW: in frames
#define AUDIO_VOICE_LOOP 0x0C // RW: the frame a loop goes back to
#define AUDIO_VOICE_POSITION 0x10 // RW: the frame playing now
#define AUDIO_VOICE_RATE 0x14 // RW: frames per second
#define AUDIO_VOICE_VOLUME 0x18 // RW: bits 0-7 left, 8-15 right

#define AUDIO_CONTROL_ON 0x01
#define AUDIO_CONTROL_LOOP 0x02
#define AUDIO_CONTROL_16BIT 0x04 // signed half-words, else signed bytes
#define AUDIO_CONTROL_STEREO 0x08 // frames of left, right
#define AUDIO_CONTROL_SIGNAL_END 0x10 // set STATUS at the end (or loop)
#define AUDIO_CONTROL_SIGNAL_HALF 0x20 // ... and at LENGTH / 2
#define AUDIO_CONTROL_MASK 0x3F

#define AUDIO_VOLUME_MASK 0xFFFF

typedef struct audio_voice {
	uint32_t control;
	uint32_t address;
	uint32_t length;
	uint32_t loop;
	uint32_t rate;
	uint32_t volume;
	uint64_t position; // in frames, 32.32 fixed point
	uint64_t step; // position advance per output frame, 32.32
} audio_voice_t;

// Eight-voice sample player: every output frame each voice that is on
// reads a frame of its sample by DMA (RAM or ROM) and moves on at its
// own rate; the card mixes them in stereo. The voices run in emulated
// time, whether the host plays the mix or not.
// IRQ line is asserted while STATUS is not 0.
typedef struct audiocard {
	pic_t* pic;
	uint8_t irq;
	bus_t dma; // reads RAM or ROM
	uint32_t clock_rate;
	uint32_t status;
	uint32_t fault;
	uint32_t master;
	audio_voice_t voice[AUDIO_VOICE_COUNT];
	// goes up by SAMPLE_RATE per tick, wraps at the clock rate
	uint64_t sample_clock;

	// output, only kept while connected to the host's speaker
	bool connected;
	int16_t frames[AUDIO_BUFFER_FRAMES * 2]; // left, right
	uint32_t frame_count; // the host takes them and lowers this
} audiocard_t;

audiocard_t* audiocard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
							  const uint32_t clock_rate);
void audiocard_destroy(audiocard_t* card);

void audiocard_reset(audiocard_t* card);
// Advances the card by that many clock ticks.
void audiocard_run(audiocard_t* card, const uint64_t ticks);
// Ticks until the next output frame (1 = the next tick) while a voice is
// on, TICKS_NEVER while all are off: then frames only make silence.
uint64_t audiocard_next_event(const audiocard_t* card);

// bus side: offset is relative to the device base; return true on bus error
bool audiocard_read(audiocard_t* card, const uint32_t offset,
					const uint8_t size, uint32_t* value);
bool audiocard_write(audiocard_t* card, const uint32_t offset,
					 const uint8_t size, const uint32_t value);

#endif // WRM_AUDIOCARD_H
