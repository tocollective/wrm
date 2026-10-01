#ifndef WRM_SPEAKER_H
#define WRM_SPEAKER_H
#include "common.h"

#include "miniaudio.h"

#include "devices/beeper.h"

// Frames of audio queued between the emulator and the host's audio
// thread, which bounds the latency: 4096 frames are ~85ms at 48kHz, a
// few 60Hz frames of the emulator's main loop.
#define SPEAKER_BUFFER_FRAMES 4096

// The host's sound output (miniaudio): plays the samples the beeper makes.
// The main loop queues them, the audio thread plays them; an empty queue
// plays silence, a full one drops the newest samples.
typedef struct speaker {
	ma_pcm_rb queue; // mono s16, single producer, single consumer
	ma_device device;
} speaker_t;

// NULL (with a warning) if the host has no sound output to use.
speaker_t* speaker_create(void);
void speaker_destroy(speaker_t* speaker);

// Queues the beeper's new samples and empties its buffer.
void speaker_play(speaker_t* speaker, beeper_t* beeper);

#endif // WRM_SPEAKER_H
