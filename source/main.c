#include <stdio.h>
#include <string.h>

#define SDL_MAIN_USE_CALLBACKS 1
#include "SDL3/SDL_main.h"

#include "application.h"

SDL_AppResult SDL_AppInit(void** appstate, int argc, char* argv[]) {
	SDL_InitFlags initFlags = SDL_INIT_VIDEO | SDL_INIT_GAMEPAD;
	if (!SDL_Init(initFlags)) error(SDL_GetError());

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
	return SDL_APP_CONTINUE;
}

void SDL_AppQuit(void* appstate, SDL_AppResult result) {
	(void)result;
	application_t* app = appstate;
	application_destroy(app);
	SDL_Quit();
}
