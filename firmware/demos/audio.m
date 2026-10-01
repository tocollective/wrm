// [12] Audio card: a chord on three voices looping one period of a wave,
// then a stream: a looping buffer of two halves that software refills as
// the voice signals it has played one.

import {
    pic, video, audio, audioVoice, IRQ_AUDIO,
    VOICE_LOOP, VOICE_16BIT, VOICE_SIGNAL_END, VOICE_SIGNAL_HALF,
} from "../defs.m"
import { puts, show } from "../lib.m"
import { FULL_VOLUME, audioInit, audioPlay, audioStop } from "../audio.m"

let WAVE_FRAMES: UWord = 64         // one period of the chord's wave
let CHORD: UWord[3] = [523, 659, 784]           // C, E and G, in Hz
let PAN: UWord[3] = [0x40C0, 0x8080, 0xC040]    // left, middle, right
let NOTE_FRAMES: UWord = 20         // video frames between the notes
let CHORD_FRAMES: UWord = 60        // and of the whole chord

let STREAM_VOICE: UWord = 3
let STREAM_BIT: UWord = 1 << 3      // its bit in STATUS
let STREAM_FRAMES: UWord = 1024     // two halves
let HALF: UWord = 512
let STREAM_HALVES: UWord = 188      // about 2 seconds at 48000 frames a second
let HZ_STEP: UWord = 89_478         // phase per frame of 1 Hz: 2^32 / 48000
let TONE_LEVEL: Half = 4000

let mut wave: Byte[64]
let mut stream: Half[1024]
let mut phase: UWord                // of the stream's square wave
let mut step: UWord

let demoAudio(): Void {
    puts("\n[12] audio: a chord, then a rising tone streamed by software\n")
    audioInit()
    makeWave()
    for v: UWord in 0..3 {
        audioPlay(v, &wave as UWord, WAVE_FRAMES, 0, CHORD[v] * WAVE_FRAMES, VOICE_LOOP, PAN[v])
        waitFrames(NOTE_FRAMES)     // the notes come in one after another
    }
    waitFrames(CHORD_FRAMES)
    for v: UWord in 0..3 audioStop(v)

    phase = 0
    step = 220 * HZ_STEP
    fill(0)
    fill(HALF)
    audioPlay(STREAM_VOICE, &stream as UWord, STREAM_FRAMES, 0, 48000,
              VOICE_LOOP | VOICE_16BIT | VOICE_SIGNAL_HALF | VOICE_SIGNAL_END, FULL_VOLUME)
    pic.enable = 1 << IRQ_AUDIO     // wakes WFI; IE stays 0
    let mut halves: UWord = 0
    while halves < STREAM_HALVES {
        wfi()
        if audio.status & STREAM_BIT == 0 continue
        audio.status = STREAM_BIT   // the line drops
        // half way the first half has been played; at the end the voice
        // has gone back to the start, and the second one has
        if audioVoice[STREAM_VOICE].position >= HALF fill(0) else fill(HALF)
        halves++
    }
    pic.enable = 0
    audioStop(STREAM_VOICE)
    show("halves streamed", halves)
}

/// One period of a triangle wave, signed bytes.
let makeWave(): Void {
    for i: UWord in 0..WAVE_FRAMES {
        let t: Word = (i % 32) as Word * 3 - 48     // -48 up to 45
        if i < 32 wave[i] = t as Byte else wave[i] = -t as Byte
    }
}

/// Fills the half of the stream from frame start with a square wave, a
/// little higher every half.
let fill(start: UWord): Void {
    for i: UWord in start..start + HALF {
        if phase < 0x8000_0000 stream[i] = TONE_LEVEL else stream[i] = -TONE_LEVEL
        phase += step
    }
    step += 4 * HZ_STEP
}

/// Returns after that many video frames (60 a second).
let waitFrames(frames: UWord): Void {
    let end: UWord = video.frame + frames
    while ((end - video.frame) as Word > 0) {}      // survives FRAME wrapping
}

export { demoAudio }
