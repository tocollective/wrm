#include "application.h"

#include <math.h>
#include <string.h>

#include "config.h"
#include "console.h"
#include "snapshot.h"
#include "web.h"

// How often the title shows the speed the machine really runs at.
#define APPLICATION_SPEED_PERIOD_NS 1000000000ULL // 1s

// Unthrottled, an iteration of the main loop runs the machine for about
// this much host time, which leaves time to draw a frame at 60Hz...
#define APPLICATION_UNTHROTTLED_NS 12000000ULL // 12ms
// ... in slices of machine time, between which the host's input comes in:
// at fixed ticks, so a deterministic run gets it at the same ones
#define APPLICATION_SLICES_PER_SECOND 100 // 10ms

// Points the CPU trace at the file or stream given by --trace.
static void application_open_trace(application_t* app) {
	const char* path = config_get()->trace_path;
	if (!path) return;

	FILE* trace = stderr;
	if (strcmp(path, "-") != 0) {
		trace = fopen(path, "w");
		if (!trace) error("Failed to open the trace file %s", path);
		app->trace_file = trace;
	}
	app->machine->motherboard->cpu->trace = trace;
}

application_t* application_create(int argc, char* argv[]) {
	application_t* app = calloc(1, sizeof(application_t));
	app->machine = machine_create();
	application_open_trace(app);
	if (!config_get()->headless) {
		app->display = display_create();
		// frames are only scanned out while a display shows them
		app->machine->motherboard->videocard->connected = true;
		if (!config_get()->mute) app->speaker = speaker_create();
		// ... and samples only made while a speaker plays them
		app->machine->motherboard->beeper->connected = app->speaker != NULL;
		app->machine->motherboard->audiocard->connected = app->speaker != NULL;
	}
	const config_t* cfg = config_get();
	if (cfg->snapshot_path && !snapshot_load(app->machine, cfg->snapshot_path))
		error("Failed to start from the snapshot %s", cfg->snapshot_path);
	if (cfg->monitor_port)
		app->monitor = monitor_create(app->machine, cfg->monitor_port);
	if (cfg->pause && app->monitor)
		app->machine->motherboard->cpu->debug.stopped = CPU_STOP_PAUSE;
	else if (cfg->pause)
		warning("--pause without a monitor: the machine runs");
	app->running = true;
	console_open();
#ifdef __EMSCRIPTEN__
	web_attach(app);
#endif
	return app;
}

void application_destroy(application_t* app) {
	if (!app) return;
#ifdef __EMSCRIPTEN__
	web_attach(NULL);
#endif
	console_close();
	app->running = false;
	// --debug: also when quitting while the machine still runs
	if (config_get()->debug && !app->stop_reported)
		cpu_dump(app->machine->motherboard->cpu, stderr);
	monitor_destroy(app->monitor);
	speaker_destroy(app->speaker);
	display_destroy(app->display);
	machine_destroy(app->machine);
	if (app->trace_file) fclose(app->trace_file);
	free(app);
}

// Moves typed bytes from the host terminal into the UART. Only what fits
// is taken, the rest waits in stdin, like hardware flow control.
static void application_update_console(application_t* app) {
	uart_t* uart = app->machine->motherboard->uart;
	uint8_t buffer[UART_RX_FIFO_SIZE];
	const size_t count = console_read(buffer, uart_rx_space(uart));
	for (size_t i = 0; i < count; i++) uart_receive(uart, buffer[i]);
}

// Dumps the CPU state on stderr once the machine has stopped: after a fault
// that halted the CPU, or for any reason with --debug.
static void application_report_stop(application_t* app) {
	if (app->stop_reported || !machine_stopped(app->machine)) return;
	app->stop_reported = true;
	const cpu_t* cpu = app->machine->motherboard->cpu;
	if (cpu->halt_fault || config_get()->debug) cpu_dump(cpu, stderr);
}

// Stops the app when the guest powers the machine off, with its exit code.
// In headless mode a halted CPU stops it too: 0 after HLT, 1 after a fault
// that couldn't be handled. The window stays open after a halt. In the
// browser the page stays too: the machine is off until its reset button.
static void application_check_stopped(application_t* app) {
	machine_t* machine = app->machine;
#ifdef __EMSCRIPTEN__
	if (machine_powered_off(machine)) {
		if (!app->off_reported)
			print("The machine is off; Reset machine starts it again");
		app->off_reported = true;
		return;
	}
#endif
	if (machine_powered_off(machine)) {
		app->exit_code = machine->motherboard->power->exit_code;
		app->running = false;
	} else if (config_get()->headless && machine_stopped(machine)) {
		app->exit_code = machine->motherboard->cpu->halt_fault ? 1 : 0;
		app->running = false;
	}
}

// Puts the speed the machine ran at over the last period in the title: a
// slow host runs fewer ticks than the clock rate, and the guest's time
// falls behind.
static void application_update_speed(application_t* app) {
	if (!app->display) return;
	const uint64_t now = SDL_GetTicksNS();
	const uint64_t elapsed = now - app->speed_ns;
	if (app->speed_ns && elapsed < APPLICATION_SPEED_PERIOD_NS) return;

	const uint64_t ticks = app->machine->ticks - app->speed_ticks;
	const bool first = app->speed_ns == 0;
	app->speed_ns = now;
	app->speed_ticks = app->machine->ticks;
	if (first) return;

	char status[sizeof(app->display->status)];
	if (machine_stopped(app->machine)) {
		snprintf(status, sizeof(status), "stopped");
	} else if (machine_held(app->machine)) {
		snprintf(status, sizeof(status), "paused");
	} else {
		const double hz = (double)ticks * 1e9 / (double)elapsed;
		const double rate = (double)app->machine->motherboard->clock->rate;
		const double percent = hz * 100.0 / rate;
		if (hz >= 1e6)
			snprintf(status, sizeof(status), "%.1f MHz", hz / 1e6);
		else if (hz >= 1e3)
			snprintf(status, sizeof(status), "%.1f kHz", hz / 1e3);
		else
			snprintf(status, sizeof(status), "%.0f Hz", hz);
		const size_t length = strlen(status);
		snprintf(
			status + length, sizeof(status) - length, " (%.0f%%)", percent);
	}
	display_set_status(app->display, status);
}

// Gives the host pointer to the machine or takes it back. Buttons held
// then count as released.
static void application_capture_mouse(application_t* app, const bool capture) {
	if (!app->display || app->display->mouse_captured == capture) return;
	display_capture_mouse(app->display, capture);
	mouse_release_buttons(app->machine->motherboard->mouse);
	app->mouse_x = 0;
	app->mouse_y = 0;
}

// Runs the machine at the clock rate, or as fast as the host can.
static void application_run_machine(application_t* app) {
	if (!config_get()->unthrottled) {
		application_update_console(app);
		machine_update(app->machine);
		return;
	}
	const uint64_t rate = app->machine->motherboard->clock->rate;
	uint64_t slice = rate / APPLICATION_SLICES_PER_SECOND;
	if (slice == 0) slice = 1;
	const uint64_t deadline = SDL_GetTicksNS() + APPLICATION_UNTHROTTLED_NS;
	do {
		application_update_console(app);
		machine_run(app->machine, slice);
	} while (!machine_stopped(app->machine) && !machine_held(app->machine)
			 && SDL_GetTicksNS() < deadline);
}

bool application_update(application_t* app) {
	monitor_poll(app->monitor);
	// the guest has disabled the mouse, or made it absolute: the pointer
	// goes back to the host
	const mouse_t* mouse = app->machine->motherboard->mouse;
	if (!mouse->enabled || mouse->absolute)
		application_capture_mouse(app, false);
	const bool held = machine_held(app->machine);
	// going on after a stop: the clock doesn't make up for the pause
	if (app->held && !held) clock_reset(app->machine->motherboard->clock);
	app->held = held;
	if (!held)
		application_run_machine(app);
	else if (!app->display) // headless: nothing to wait for but the monitor
		SDL_Delay(1);
	application_update_speed(app);
	display_render(app->display, app->machine->motherboard->videocard);
	speaker_play(app->speaker,
				 app->machine->motherboard->beeper,
				 app->machine->motherboard->audiocard);
	application_report_stop(app);
	application_check_stopped(app);
	return true;
}

// SDL's button number as the mouse's button bit, 0 for others
static uint32_t application_mouse_button(const Uint8 button) {
	switch (button) {
		case SDL_BUTTON_LEFT:
			return MOUSE_BUTTON_LEFT;
		case SDL_BUTTON_RIGHT:
			return MOUSE_BUTTON_RIGHT;
		case SDL_BUTTON_MIDDLE:
			return MOUSE_BUTTON_MIDDLE;
	}
	return 0;
}

// Passes the whole part of the motion so far to the mouse; the fraction
// waits for the next motion.
static void application_mouse_motion(application_t* app, const float dx,
									 const float dy) {
	app->mouse_x += dx;
	app->mouse_y += dy;
	const float x = truncf(app->mouse_x);
	const float y = truncf(app->mouse_y);
	app->mouse_x -= x;
	app->mouse_y -= y;
	mouse_move(app->machine->motherboard->mouse, (int32_t)x, (int32_t)y);
}

// An absolute mouse follows the host's pointer over the window, in the
// pixels of the video mode, without capturing it.
static void application_mouse_point(application_t* app, const float x,
									const float y) {
	motherboard_t* mb = app->machine->motherboard;
	uint32_t width, height, frame_x, frame_y;
	videocard_mode_size(mb->videocard, &width, &height);
	display_frame_point(
			app->display, x, y, width, height, &frame_x, &frame_y);
	mouse_point(mb->mouse, frame_x, frame_y);
}

static void application_absolute_mouse_event(application_t* app,
											 SDL_Event* event) {
	mouse_t* mouse = app->machine->motherboard->mouse;
	switch (event->type) {
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			application_mouse_point(app, event->button.x, event->button.y);
			mouse_button(mouse,
						 application_mouse_button(event->button.button),
						 event->type == SDL_EVENT_MOUSE_BUTTON_DOWN);
			break;
		case SDL_EVENT_MOUSE_MOTION:
			application_mouse_point(app, event->motion.x, event->motion.y);
			break;
		case SDL_EVENT_MOUSE_WHEEL:
			application_mouse_point(
					app, event->wheel.mouse_x, event->wheel.mouse_y);
			mouse_wheel(mouse, event->wheel.integer_y);
			break;
	}
}

// Mouse events go to the machine only while it has the pointer; a click
// gives it the pointer once software has enabled the mouse. An absolute
// mouse has them all, with no capture.
static void application_mouse_event(application_t* app, SDL_Event* event) {
	mouse_t* mouse = app->machine->motherboard->mouse;
	if (app->display && mouse->enabled && mouse->absolute) {
		application_absolute_mouse_event(app, event);
		return;
	}
	const bool captured = app->display && app->display->mouse_captured;
	switch (event->type) {
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
			// the click that captures the pointer is not an event
			if (!captured && mouse->enabled)
				application_capture_mouse(app, true);
			else if (captured)
				mouse_button(mouse,
							 application_mouse_button(event->button.button),
							 true);
			break;
		case SDL_EVENT_MOUSE_BUTTON_UP:
			if (captured)
				mouse_button(mouse,
							 application_mouse_button(event->button.button),
							 false);
			break;
		case SDL_EVENT_MOUSE_MOTION:
			if (captured)
				application_mouse_motion(
						app, event->motion.xrel, event->motion.yrel);
			break;
		case SDL_EVENT_MOUSE_WHEEL:
			if (captured) mouse_wheel(mouse, event->wheel.integer_y);
			break;
	}
}

// Closing the window or Ctrl+C. The first time it asks the guest to power
// off, like a power button, if the guest listens: the power controller's
// IRQ line is enabled in the PIC and the machine still runs. Otherwise,
// and the second time, the app quits at once. Returns true to quit.
static bool application_quit(application_t* app) {
	motherboard_t* mb = app->machine->motherboard;
	const bool listens = (mb->pic->enable & (1u << MB_IRQ_POWER)) != 0;
	if (app->off_requested || !listens || machine_stopped(app->machine)) {
		app->running = false;
		return true;
	}
	app->off_requested = true;
	power_request_off(mb->power);
	print("Asked the machine to power off; quit again to force it");
	return false;
}

// Ctrl+Alt+R: resets the machine, also after it has halted.
void application_reset(application_t* app) {
	machine_reset(app->machine);
	app->stop_reported = false;
	app->off_requested = false;
	app->off_reported = false;
	print("Reset");
}

bool application_process_events(application_t* app, SDL_Event* event) {
	switch (event->type) {
		case SDL_EVENT_QUIT:
		case SDL_EVENT_WINDOW_CLOSE_REQUESTED: {
			return application_quit(app);
		} break;
		case SDL_EVENT_DROP_FILE: {
			// a disk image dropped on the window goes in the floppy drive
			if (event->drop.data)
				disk_insert(app->machine->motherboard->floppy, event->drop.data);
		} break;
		case SDL_EVENT_WINDOW_FOCUS_LOST: {
			application_capture_mouse(app, false);
			// an absolute mouse has no capture to end: the buttons go up
			if (app->machine->motherboard->mouse->absolute)
				mouse_release_buttons(app->machine->motherboard->mouse);
		} break;
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
		case SDL_EVENT_MOUSE_MOTION:
		case SDL_EVENT_MOUSE_WHEEL: {
			application_mouse_event(app, event);
		} break;
		case SDL_EVENT_KEY_DOWN:
		case SDL_EVENT_KEY_UP: {
			// Ctrl+Alt gives the pointer back; the keys still reach the
			// guest, except R of Ctrl+Alt+R, which resets the machine, and
			// S and L, which save and load a snapshot
			if (event->type == SDL_EVENT_KEY_DOWN
				&& (event->key.mod & SDL_KMOD_CTRL)
				&& (event->key.mod & SDL_KMOD_ALT)) {
				application_capture_mouse(app, false);
				if (event->key.scancode == SDL_SCANCODE_R) {
					if (!event->key.repeat) application_reset(app);
					break;
				}
				if (event->key.scancode == SDL_SCANCODE_S) {
					if (!event->key.repeat
						&& snapshot_save(app->machine,
										 APPLICATION_SNAPSHOT_PATH))
						print("Saved %s", APPLICATION_SNAPSHOT_PATH);
					break;
				}
				if (event->key.scancode == SDL_SCANCODE_L) {
					if (!event->key.repeat
						&& snapshot_load(app->machine,
										 APPLICATION_SNAPSHOT_PATH)) {
						app->stop_reported = false;
						app->off_requested = false;
						app->off_reported = false;
						print("Loaded %s", APPLICATION_SNAPSHOT_PATH);
					}
					break;
				}
			}
			if (event->key.repeat) break; // firmware does its own repeat
			// SDL scancodes are USB HID usage IDs
			keyboard_key(app->machine->motherboard->keyboard,
						 (uint16_t)event->key.scancode,
						 event->type == SDL_EVENT_KEY_DOWN);
		} break;
	}

	return false;
}
