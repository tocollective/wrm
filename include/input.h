#ifndef WRM_INPUT_H
#define WRM_INPUT_H
#include "common.h"

#include "motherboard.h"

// Input script (--input): what the host feeds the machine, at the clock
// ticks it says, so a run with it is the same every time. One event per
// line, '#' starts a comment:
//
//   TICK key USAGE down|up        a key, USAGE is its USB HID usage ID
//   TICK uart TEXT                bytes for the UART: the rest of the line,
//                                 with \n, \r, \t, \\ and \xNN escapes
//                                 ('#' is \x23, a space at the end \x20)
//   TICK mouse DX DY              mouse motion (relative mode)
//   TICK point X Y                where the pointer is (absolute mode)
//   TICK button left|right|middle down|up
//   TICK wheel STEPS
//   TICK power                    the power button: asks to power off
//
// TICK is the number of clock ticks run since power-on when the event
// comes, before the next tick runs; +N means N ticks after the event
// before it. Events must come in order. Like the host's input, they reach
// the devices as they are: a full FIFO drops them, a disabled mouse
// ignores them, and so does a mouse in the other mode.

typedef enum input_kind {
	INPUT_KEY,
	INPUT_UART,
	INPUT_MOUSE,
	INPUT_POINT,
	INPUT_BUTTON,
	INPUT_WHEEL,
	INPUT_POWER,
} input_kind_t;

typedef struct input_event {
	uint64_t tick;
	input_kind_t kind;
	int32_t a, b; // key: usage, down; mouse: dx, dy; point: x, y;
				  // button: bit, down; wheel: steps
	char* text; // uart: the bytes, length in a
} input_event_t;

typedef struct input {
	input_event_t* events;
	size_t count;
	size_t next; // the first event not fed yet
} input_t;

// Reads the script at path; exits with an error if it can't.
input_t* input_load(const char* path);
void input_destroy(input_t* input);

// The tick of the next event, TICKS_NEVER if there are no more.
uint64_t input_next_tick(const input_t* input);
// Feeds the devices the events due by tick (ticks run so far).
void input_feed(input_t* input, const uint64_t tick, motherboard_t* mb);
// Goes on with the first event at tick or after it (a snapshot was loaded).
void input_seek(input_t* input, const uint64_t tick);

#endif // WRM_INPUT_H
