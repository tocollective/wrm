#ifndef WRM_CONSOLE_H
#define WRM_CONSOLE_H
#include "common.h"

// Host terminal on the other end of the UART: stdin feeds the RX line,
// transmitted bytes already go to stdout (see devices/uart.h).
// When stdin is a terminal it is switched to raw mode without local echo,
// so every typed byte reaches the machine at once and only the firmware's
// echo shows up on screen. Ctrl+C still works.

// Prepares stdin; the terminal is restored by console_close or at exit.
void console_open(void);
void console_close(void);

// Reads up to size pending bytes without blocking, returns the count.
size_t console_read(uint8_t* buffer, const size_t size);

#endif // WRM_CONSOLE_H
