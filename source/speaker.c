#include "speaker.h"

#include <string.h>

// Audio thread: plays what is queued, then silence for the rest.
static void speaker_callback(ma_device* device, void* output,
							 const void* input, ma_uint32 frames) {
	(void)input;
	speaker_t* speaker = device->pUserData;
	int16_t* out = output;
	const ma_uint32 channels = device->playback.channels;
	while (frames > 0) {
		ma_uint32 count = frames;
		void* buffer = NULL;
		if (ma_pcm_rb_acquire_read(&speaker->queue, &count, &buffer)
				!= MA_SUCCESS
			|| count == 0)
			break;
		memcpy(out, buffer, count * channels * sizeof(int16_t));
		ma_pcm_rb_commit_read(&speaker->queue, count);
		out += count * channels;
		frames -= count;
	}
	memset(out, 0, frames * channels * sizeof(int16_t));
}

speaker_t* speaker_create(void) {
	speaker_t* speaker = (speaker_t*)calloc(1, sizeof(speaker_t));
	if (!speaker) error("Failed to allocate speaker!");

	if (ma_pcm_rb_init(ma_format_s16,
					   2,
					   SPEAKER_BUFFER_FRAMES,
					   NULL,
					   NULL,
					   &speaker->queue)
		!= MA_SUCCESS)
		error("Failed to allocate the audio queue!");

	ma_device_config config = ma_device_config_init(ma_device_type_playback);
	config.playback.format = ma_format_s16;
	config.playback.channels = 2;
	config.sampleRate = AUDIO_SAMPLE_RATE; // miniaudio converts if need be
	config.dataCallback = speaker_callback;
	config.pUserData = speaker;

	if (ma_device_init(NULL, &config, &speaker->device) != MA_SUCCESS) {
		warning("No sound: failed to open the audio device");
		ma_pcm_rb_uninit(&speaker->queue);
		free(speaker);
		return NULL;
	}
	if (ma_device_start(&speaker->device) != MA_SUCCESS) {
		warning("No sound: failed to start the audio device");
		ma_device_uninit(&speaker->device);
		ma_pcm_rb_uninit(&speaker->queue);
		free(speaker);
		return NULL;
	}
	return speaker;
}

void speaker_destroy(speaker_t* speaker) {
	if (!speaker) return;
	// stops the audio thread before the queue goes away
	ma_device_uninit(&speaker->device);
	ma_pcm_rb_uninit(&speaker->queue);
	free(speaker);
	speaker = NULL;
}

static int16_t speaker_clip(const int32_t value) {
	if (value < INT16_MIN) return INT16_MIN;
	if (value > INT16_MAX) return INT16_MAX;
	return (int16_t)value;
}

void speaker_play(speaker_t* speaker, beeper_t* beeper, audiocard_t* card) {
	if (!speaker || !beeper || !card) return;
	// both make a frame on the same ticks, so they have as many; what one
	// has more of waits for the next call
	const uint32_t frames = beeper->sample_count < card->frame_count
								? beeper->sample_count
								: card->frame_count;
	for (uint32_t i = 0; i < frames; i++) {
		const int32_t beep = beeper->samples[i];
		speaker->mix[i * 2] = speaker_clip(card->frames[i * 2] + beep);
		speaker->mix[i * 2 + 1] = speaker_clip(card->frames[i * 2 + 1] + beep);
	}
	beeper->sample_count -= frames;
	memmove(beeper->samples,
			beeper->samples + frames,
			beeper->sample_count * sizeof(int16_t));
	card->frame_count -= frames;
	memmove(card->frames,
			card->frames + frames * 2,
			card->frame_count * 2 * sizeof(int16_t));

	const int16_t* mix = speaker->mix;
	ma_uint32 left = frames;
	// the queue is a ring: a write may take two pieces
	while (left > 0) {
		ma_uint32 count = left;
		void* buffer = NULL;
		if (ma_pcm_rb_acquire_write(&speaker->queue, &count, &buffer)
				!= MA_SUCCESS
			|| count == 0)
			return; // full: the rest is dropped
		memcpy(buffer, mix, count * 2 * sizeof(int16_t));
		ma_pcm_rb_commit_write(&speaker->queue, count);
		mix += count * 2;
		left -= count;
	}
}
