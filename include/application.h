#ifndef WRM_APPLICATION_H
#define WRM_APPLICATION_H
#include "display.h"
#include "machine.h"
#include "monitor.h"
#include "speaker.h"

// Where Ctrl+Alt+S saves a snapshot and Ctrl+Alt+L loads it from
#define APPLICATION_SNAPSHOT_PATH "wrm081632.snap"

typedef struct application {
	bool running;
	bool stop_reported; // the machine has stopped and the state was dumped
	bool off_requested; // the guest was asked to power off: next quit forces
	int exit_code; // process exit status once the app stops running
	machine_t* machine;
	display_t* display; // NULL in headless mode
	speaker_t* speaker; // NULL in headless mode, with --mute or no audio
	monitor_t* monitor; // NULL without --monitor
	bool held; // the debugger had stopped the machine at the last update
	FILE* trace_file; // --trace=PATH, NULL when off or on stderr
	float mouse_x, mouse_y; // motion the mouse hasn't been given yet
	uint64_t speed_ns; // host time of the last speed sample
	uint64_t speed_ticks; // machine ticks run by then
} application_t;

application_t* application_create(int argc, char* argv[]);
void application_destroy(application_t* app);

bool application_update(application_t* app);
bool application_process_events(application_t* app, SDL_Event* event);

#endif // WRM_APPLICATION_H
