#include <stdio.h>
#include <string.h>

#define SDL_MAIN_USE_CALLBACKS 1
#include "SDL3/SDL_main.h"

#include "application.h"
#include "config.h"

// Iterations per second in headless mode: with no vsync to wait for, the
// main loop would otherwise spin a host core at 100%.
#define HEADLESS_ITERATION_RATE "1000"

SDL_AppResult SDL_AppInit(void** appstate, int argc, char* argv[]) {
	config_parse(argc, argv);
	const bool headless = config_get()->headless;

	// closing the window asks the guest to power off first (application.c)
	SDL_SetHint(SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
	// SDL brings up the events subsystem on its own, so Ctrl+C still quits
	SDL_InitFlags initFlags = 0;
	if (!headless) initFlags = SDL_INIT_VIDEO | SDL_INIT_GAMEPAD;
	if (!SDL_Init(initFlags)) error(SDL_GetError());
	// unthrottled, every iteration runs the machine as long as it can
	if (headless)
		SDL_SetHint(SDL_HINT_MAIN_CALLBACK_RATE,
					config_get()->unthrottled ? "0" : HEADLESS_ITERATION_RATE);

	*appstate = application_create(argc, argv);
	if (*appstate == NULL) return SDL_APP_FAILURE;
	return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void* appstate, SDL_Event* event) {
	application_t* app = appstate;

	if (application_process_events(app, event) || !app->running)
		return SDL_APP_SUCCESS;

	return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void* appstate) {
	application_t* app = appstate;
	if (!application_update(app)) return SDL_APP_FAILURE;
	if (!app->running) return SDL_APP_SUCCESS;
	return SDL_APP_CONTINUE;
}

void SDL_AppQuit(void* appstate, SDL_AppResult result) {
	(void)result;
	application_t* app = appstate;
	const int exit_code = app ? app->exit_code : 0;
	application_destroy(app);
	SDL_Quit();
#ifndef __EMSCRIPTEN__
	// SDL only knows success and failure; pass the guest's code on
	if (exit_code != 0) exit(exit_code);
#endif
}
