// The web build's side of its page, web/shell.html: functions the page
// calls (ccall) and its hooks the emulator calls.
#ifdef __EMSCRIPTEN__

#include "web.h"

#include "application.h"

#include <emscripten.h>

static application_t* web_app;

void web_attach(application_t* app) {
	web_app = app;
}

EM_JS(void, web_persist_page, (void), {
	if (Module.wrmPersist) Module.wrmPersist();
});

void web_persist(void) {
	web_persist_page();
}

// The page has put a disk image at path: into the floppy drive with it.
EMSCRIPTEN_KEEPALIVE void web_floppy_insert(const char* path) {
	if (web_app) disk_insert(web_app->machine->motherboard->floppy, path);
}

EMSCRIPTEN_KEEPALIVE void web_floppy_eject(void) {
	if (web_app) disk_eject(web_app->machine->motherboard->floppy);
}

// The page's reset button: like Ctrl+Alt+R, also after a power-off.
EMSCRIPTEN_KEEPALIVE void web_reset(void) {
	if (web_app) application_reset(web_app);
}

#endif // __EMSCRIPTEN__
