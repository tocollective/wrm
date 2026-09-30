#ifndef WRM_DISPLAY_H
#define WRM_DISPLAY_H
#include "common.h"

#include <SDL3/SDL.h>

typedef struct display {
	SDL_Window* window;
	SDL_Renderer* renderer;
	SDL_Texture* texture;
} display_t;

display_t* display_create(void);
void display_destroy(display_t* display);

void display_render(display_t* display);

#endif // WRM_DISPLAY_H
