#include "application.h"

application_t* application_create(int argc, char* argv[]) {
	application_t* app = calloc(1, sizeof(application_t));
	app->machine = machine_create();
	app->display = display_create();
	app->running = true;
	return app;
}

void application_destroy(application_t* app) {
	if (!app) return;
	if (!app->running) return;
	app->running = false;
	display_destroy(app->display);
	machine_destroy(app->machine);
}

bool application_update(application_t* app) {
	machine_update(app->machine);
	display_render(app->display);
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
	}

	return false;
}
