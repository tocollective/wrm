#include "display.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#define DISPLAY_TITLE "WRM.081632"
#define DISPLAY_TITLE_CAPTURED " - Ctrl+Alt releases the mouse"

// "WRM.081632 - <status> - <how to release the mouse>"
static void display_update_title(display_t* display) {
	char title[sizeof(DISPLAY_TITLE) + sizeof(display->status)
			   + sizeof(DISPLAY_TITLE_CAPTURED) + 3];
	snprintf(title,
			 sizeof(title),
			 "%s%s%s%s",
			 DISPLAY_TITLE,
			 display->status[0] ? " - " : "",
			 display->status,
			 display->mouse_captured ? DISPLAY_TITLE_CAPTURED : "");
	SDL_SetWindowTitle(display->window, title);
}

display_t* display_create(void) {
	display_t* display = (display_t*)calloc(1, sizeof(display_t));
	if (!display) error("Failed to allocate display!");

	const SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE;
	display->window = SDL_CreateWindow(DISPLAY_TITLE, 640, 480, flags);
	if (!display->window) error(SDL_GetError());

	display->renderer = SDL_CreateRenderer(display->window, NULL);
	if (!display->renderer) error(SDL_GetError());

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

// (Re)creates the texture at the size of the video mode.
static void display_resize(display_t* display, const int width,
						   const int height) {
	if (display->texture) {
		float texture_width, texture_height;
		SDL_GetTextureSize(display->texture, &texture_width, &texture_height);
		if ((int)texture_width == width && (int)texture_height == height)
			return;
		SDL_DestroyTexture(display->texture);
	}

	const SDL_PixelFormat format = SDL_PIXELFORMAT_XRGB8888;
	const SDL_TextureAccess access = SDL_TEXTUREACCESS_STREAMING;
	display->texture =
		SDL_CreateTexture(display->renderer, format, access, width, height);
	if (!display->texture) error(SDL_GetError());
	SDL_SetTextureScaleMode(display->texture, SDL_SCALEMODE_NEAREST);
}

// Copies a new frame of the video card into the texture.
static void display_update(display_t* display, const videocard_t* videocard) {
	if (!videocard || videocard->screen_updates == display->screen_updates)
		return;
	display->screen_updates = videocard->screen_updates;

	const int width = (int)videocard->screen_width;
	const int height = (int)videocard->screen_height;
	display_resize(display, width, height);
	const int pitch = width * (int)sizeof(uint32_t);
	if (!SDL_UpdateTexture(display->texture, NULL, videocard->screen, pitch))
		error(SDL_GetError());
}

// Where a width x height frame is shown in the window: scaled to fit, with
// the aspect ratio kept, in the middle.
static SDL_FRect display_frame_rect(const display_t* display, const float width,
									const float height) {
	int window_width, window_height;
	SDL_GetWindowSize(display->window, &window_width, &window_height);
	const float ratio =
		fminf((float)window_width / width, (float)window_height / height);
	const SDL_FRect rect = {
		(window_width - width * ratio) / 2,
		(window_height - height * ratio) / 2,
		width * ratio,
		height * ratio,
	};
	return rect;
}

static uint32_t display_clamp(const float value, const uint32_t size) {
	if (!(value >= 0)) return 0; // NaN too
	if (value >= (float)size) return size - 1;
	return (uint32_t)value;
}

void display_frame_point(const display_t* display, const float x, const float y,
						 const uint32_t width, const uint32_t height,
						 uint32_t* frame_x, uint32_t* frame_y) {
	const SDL_FRect rect =
		display_frame_rect(display, (float)width, (float)height);
	*frame_x = display_clamp((x - rect.x) * (float)width / rect.w, width);
	*frame_y = display_clamp((y - rect.y) * (float)height / rect.h, height);
}

void display_render(display_t* display, const videocard_t* videocard) {
	if (!display) return;
	display_update(display, videocard);
	SDL_Renderer* renderer = display->renderer;
	SDL_Texture* texture = display->texture;

	SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
	SDL_RenderClear(renderer);
	if (texture) {
		float texture_width, texture_height;
		SDL_GetTextureSize(texture, &texture_width, &texture_height);
		const SDL_FRect rect =
			display_frame_rect(display, texture_width, texture_height);
		SDL_RenderTexture(renderer, texture, NULL, &rect);
	}
	SDL_RenderPresent(renderer);
}

void display_capture_mouse(display_t* display, const bool capture) {
	if (!display || display->mouse_captured == capture) return;
	if (!SDL_SetWindowRelativeMouseMode(display->window, capture)) {
		warning("Mouse: %s", SDL_GetError());
		return;
	}
	display->mouse_captured = capture;
	display_update_title(display);
}

void display_set_status(display_t* display, const char* status) {
	if (!display
		|| strncmp(display->status, status, sizeof(display->status)) == 0)
		return;
	snprintf(display->status, sizeof(display->status), "%s", status);
	display_update_title(display);
}
