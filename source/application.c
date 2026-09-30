#include "application.h"

#include <string.h>

#include "config.h"
#include "console.h"

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
	if (!config_get()->headless) app->display = display_create();
	app->running = true;
	console_open();
	return app;
}

void application_destroy(application_t* app) {
	if (!app) return;
	console_close();
	app->running = false;
	// --debug: also when quitting while the machine still runs
	if (config_get()->debug && !app->stop_reported)
		cpu_dump(app->machine->motherboard->cpu, stderr);
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
// that couldn't be handled. The window stays open after a halt.
static void application_check_stopped(application_t* app) {
	machine_t* machine = app->machine;
	if (machine_powered_off(machine)) {
		app->exit_code = machine->motherboard->power->exit_code;
		app->running = false;
	} else if (config_get()->headless && machine_stopped(machine)) {
		app->exit_code = machine->motherboard->cpu->halt_fault ? 1 : 0;
		app->running = false;
	}
}

bool application_update(application_t* app) {
	application_update_console(app);
	machine_update(app->machine);
	display_render(app->display);
	application_report_stop(app);
	application_check_stopped(app);
	return true;
}

bool application_process_events(application_t* app, SDL_Event* event) {
	switch (event->type) {
		case SDL_EVENT_QUIT: {
			app->running = false;
			return true;
		} break;
		case SDL_EVENT_WINDOW_CLOSE_REQUESTED: {
			app->running = false;
			return true;
		} break;
		case SDL_EVENT_KEY_DOWN:
		case SDL_EVENT_KEY_UP: {
			if (event->key.repeat) break; // firmware does its own repeat
			// SDL scancodes are USB HID usage IDs
			keyboard_key(app->machine->motherboard->keyboard,
						 (uint16_t)event->key.scancode,
						 event->type == SDL_EVENT_KEY_DOWN);
		} break;
	}

	return false;
}
