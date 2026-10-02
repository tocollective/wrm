#ifndef WRM_DISPLAY_H
#define WRM_DISPLAY_H
#include "common.h"

#include <SDL3/SDL.h>

#include "devices/videocard.h"

// The monitor: shows the frames the video card scans out, scaled to the
// window with the aspect ratio kept.
typedef struct display {
	SDL_Window* window;
	SDL_Renderer* renderer;
	SDL_Texture* texture; // NULL until the first frame
	uint64_t screen_updates; // of the frame in the texture
	bool mouse_captured; // the host pointer belongs to the machine
	char status[48]; // shown in the title after the name, e.g. the speed
} display_t;

display_t* display_create(void);
void display_destroy(display_t* display);

void display_render(display_t* display, const videocard_t* videocard);
// Gives the host pointer to the machine (hidden, relative motion) or
// back to the host; the title says how to get it back.
void display_capture_mouse(display_t* display, const bool capture);
// The pixel of a width x height frame under the point (x, y) of the window,
// as the frame is shown; a point beside the frame gives its nearest edge.
void display_frame_point(const display_t* display, const float x,
						 const float y, const uint32_t width,
						 const uint32_t height, uint32_t* frame_x,
						 uint32_t* frame_y);
// Text the title shows after the machine's name, "" for none.
void display_set_status(display_t* display, const char* status);

#endif // WRM_DISPLAY_H
