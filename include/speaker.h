#ifndef WRM_SPEAKER_H
#define WRM_SPEAKER_H
#include "common.h"

#include "miniaudio.h"

#include "devices/audiocard.h"
#include "devices/beeper.h"

// Frames of audio queued between the emulator and the host's audio
// thread, which bounds the latency: 4096 frames are ~85ms at 48kHz, a
// few 60Hz frames of the emulator's main loop.
#define SPEAKER_BUFFER_FRAMES 4096

// The host's sound output (miniaudio): plays the mix of the audio card and
// the beeper. The main loop queues it, the audio thread plays it; an empty
// queue plays silence, a full one drops the newest frames.
typedef struct speaker {
	ma_pcm_rb queue; // stereo s16, single producer, single consumer
	ma_device device;
	int16_t mix[AUDIO_BUFFER_FRAMES * 2]; // left, right
} speaker_t;

// NULL (with a warning) if the host has no sound output to use.
speaker_t* speaker_create(void);
void speaker_destroy(speaker_t* speaker);

// Mixes the frames both devices have made, queues them and takes them out
// of the devices' buffers.
void speaker_play(speaker_t* speaker, beeper_t* beeper, audiocard_t* card);

#endif // WRM_SPEAKER_H
