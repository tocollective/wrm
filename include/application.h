#ifndef WRM_APPLICATION_H
#define WRM_APPLICATION_H
#include "display.h"
#include "machine.h"

typedef struct application {
	bool running;
	int exit_code; // process exit status once the app stops running
	machine_t* machine;
	display_t* display; // NULL in headless mode
} application_t;

application_t* application_create(int argc, char* argv[]);
void application_destroy(application_t* app);

bool application_update(application_t* app);
bool application_process_events(application_t* app, SDL_Event* event);

#endif // WRM_APPLICATION_H
