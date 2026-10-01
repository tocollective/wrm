// Audio card: playing samples on its eight voices.
//
// A sample is an array of frames in RAM or ROM: signed bytes, or signed
// half-words with VOICE_16BIT, and pairs of them (left, right) with
// VOICE_STEREO. Each voice plays at its own rate in frames a second and
// has a volume per side; the card mixes them at 48000 frames a second.

import { audio, audioVoice, VOICE_ON, AUDIO_VOICES } from "defs.m"

let FULL_VOLUME: UWord = 0xFFFF         // 255 left | 255 right << 8

/// Stops every voice, drops their signals and faults, and sets the mix to
/// full volume (it is silent after reset).
let audioInit(): Void {
    for v: UWord in 0..AUDIO_VOICES audioVoice[v].control = 0
    audio.status = 0xFF
    audio.fault = 0xFF
    audio.master = FULL_VOLUME
}

/// Plays length frames at address on voice v from the first frame. flags:
/// the CONTROL bits besides VOICE_ON (format, loop, signals); a loop goes
/// back to frame loopFrame. volume: left | right << 8.
let audioPlay(v: UWord, address: UWord, length: UWord, loopFrame: UWord,
              rate: UWord, flags: UWord, volume: UWord): Void {
    audioVoice[v].control = 0           // stopped while it is set up
    audioVoice[v].address = address
    audioVoice[v].length = length
    audioVoice[v].loop = loopFrame
    audioVoice[v].rate = rate
    audioVoice[v].volume = volume
    audioVoice[v].position = 0
    audioVoice[v].control = flags | VOICE_ON
}

let audioStop(v: UWord): Void {
    audioVoice[v].control = 0
}

/// Voice v is on: it hasn't reached the end of a sample without a loop.
let audioPlaying(v: UWord): Bool {
    return audioVoice[v].control & VOICE_ON != 0
}

export { FULL_VOLUME, audioInit, audioPlay, audioStop, audioPlaying }
