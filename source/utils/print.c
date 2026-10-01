#include "utils/print.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

// stdout belongs to the UART, so the emulator's own messages go to stderr.
void print(const char* msg, ...) {
	va_list args;
	va_start(args, msg);
	vfprintf(stderr, msg, args);
	va_end(args);
	fprintf(stderr, "\n");
}

void warning(const char* msg, ...) {
	fprintf(stderr, "WARNING: ");
	va_list args;
	va_start(args, msg);
	vfprintf(stderr, msg, args);
	va_end(args);
	fprintf(stderr, "\n");
}

void error(const char* msg, ...) {
	fprintf(stderr, "ERROR: ");
	va_list args;
	va_start(args, msg);
	vfprintf(stderr, msg, args);
	va_end(args);
	fprintf(stderr, "\n");
	exit(1);
}
