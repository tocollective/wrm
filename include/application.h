#ifndef WRM_APPLICATION_H
#define WRM_APPLICATION_H
#include "display.h"
#include "machine.h"
#include "speaker.h"

typedef struct application {
	bool running;
	bool stop_reported; // the machine has stopped and the state was dumped
	int exit_code; // process exit status once the app stops running
	machine_t* machine;
	display_t* display; // NULL in headless mode
	speaker_t* speaker; // NULL in headless mode, with --mute or no audio
	FILE* trace_file; // --trace=PATH, NULL when off or on stderr
} application_t;

application_t* application_create(int argc, char* argv[]);
void application_destroy(application_t* app);

bool application_update(application_t* app);
bool application_process_events(application_t* app, SDL_Event* event);

#endif // WRM_APPLICATION_H
