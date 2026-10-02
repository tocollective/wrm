#ifndef WRM_WEB_H
#define WRM_WEB_H
#include "common.h"

// The web build's side of its page (web/shell.html). The page keeps the
// disk images in the browser (IndexedDB) and gives the machine the ones
// saved there; these let it reach the machine and be told to save.
#ifdef __EMSCRIPTEN__

struct application;

// The app whose machine the page's buttons act on.
void web_attach(struct application* app);
// Something written to a disk image should be saved soon: the guest asked
// for its writes to be durable (FLUSH).
void web_persist(void);

#endif // __EMSCRIPTEN__

#endif // WRM_WEB_H
