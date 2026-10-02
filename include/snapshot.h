#ifndef WRM_SNAPSHOT_H
#define WRM_SNAPSHOT_H
#include "common.h"

#include "machine.h"

// A snapshot holds the whole state of the machine: the CPU with what is
// in its pipeline and TLB, RAM, VRAM and every device, so a machine loaded
// from it runs on exactly as the saved one would have. Some things stay
// outside:
// - Disk images are only referenced, by path, size and modification time:
//   loading warns if one is not the same any more. The floppy drive gets
//   the disk it had back.
// - The host's network connections can't be saved: sockets that were open
//   are closed by the other end (EVENTS.CLOSED, ERROR = network), a DNS
//   lookup fails.
// - Neither can the shared folder's open files: every handle is closed.
//   Nor the random number generator's bits from the host: it takes new
//   ones.
// - The ROM isn't saved; a snapshot only loads with the same ROM, clock
//   rate and RAM.
// - The emulator's own state stays as it is: breakpoints, a stop of the
//   debugger, the speed, the host's input not taken yet.
// Snapshots are made by one build of the emulator for the same build: the
// format has a version, and an older one isn't read.
#define SNAPSHOT_VERSION 2

// Saves the machine to path; false (with a warning) if it can't.
bool snapshot_save(const machine_t* machine, const char* path);
// Loads the machine from path; false (with a warning), leaving the machine
// as it was, if the file isn't a snapshot this machine can load.
bool snapshot_load(machine_t* machine, const char* path);

#endif // WRM_SNAPSHOT_H
