#include "utils/print.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void print(const char* msg, ...) {
	va_list args;
	va_start(args, msg);
	vfprintf(stdout, msg, args);
	va_end(args);
	fprintf(stdout, "\n");
}

void warning(const char* msg, ...) {
	fprintf(stderr, "WARNING: ");
	va_list args;
	va_start(args, msg);
	vfprintf(stderr, msg, args);
	va_end(args);
	fprintf(stderr, "\n");
	exit(1);
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
