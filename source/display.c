#include "display.h"

#include <math.h>

display_t* display_create(void) {
	display_t* display = (display_t*)calloc(1, sizeof(display_t));
	if (!display) error("Failed to allocate display!");

	const SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE;
	display->window = SDL_CreateWindow("WRM.081632", 800, 600, flags);
	if (!display->window) error(SDL_GetError());

	display->renderer = SDL_CreateRenderer(display->window, NULL);
	if (!display->renderer) error(SDL_GetError());

	const SDL_PixelFormat format = SDL_PIXELFORMAT_ARGB8888;
	const SDL_TextureAccess access = SDL_TEXTUREACCESS_STREAMING;
	display->texture =
		SDL_CreateTexture(display->renderer, format, access, 640, 480);
	if (!display->texture) error(SDL_GetError());

	return display;
}

void display_destroy(display_t* display) {
	if (!display) return;
	if (display->texture) {
		SDL_DestroyTexture(display->texture);
		display->texture = NULL;
	}

	if (display->renderer) {
		SDL_DestroyRenderer(display->renderer);
		display->renderer = NULL;
	}

	if (display->window) {
		SDL_DestroyWindow(display->window);
		display->window = NULL;
	}

	free(display);
	display = NULL;
}

void display_render(display_t* display) {
	if (!display) return;
	SDL_Renderer* renderer = display->renderer;
	SDL_Window* window = display->window;
	SDL_Texture* texture = display->texture;

	SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
	SDL_RenderClear(renderer);
	{
		int window_width, window_height;
		SDL_GetWindowSize(window, &window_width, &window_height);
		float texture_width, texture_height;
		SDL_GetTextureSize(texture, &texture_width, &texture_height);

		const float ratio = fminf((float)window_width / texture_width,
								  (float)window_height / texture_height);
		SDL_FRect rect = {
			(window_width - texture_width * ratio) / 2,
			(window_height - texture_height * ratio) / 2,
			texture_width * ratio,
			texture_height * ratio,
		};
		SDL_RenderTexture(renderer, texture, NULL, &rect);
	}
	SDL_RenderPresent(renderer);
}
