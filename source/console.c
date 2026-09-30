#define _POSIX_C_SOURCE 200809L // termios, fcntl and read under strict C99

#include "console.h"

#ifdef _WIN32

#include <conio.h>

void console_open(void) {
}

void console_close(void) {
}

size_t console_read(uint8_t* buffer, const size_t size) {
	size_t count = 0;
	while (count < size && _kbhit()) {
		const int c = _getch();
		buffer[count++] = c == '\r' ? '\n' : (uint8_t)c; // match ICRNL
	}
	return count;
}

#else

#include <errno.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

static struct {
	bool open;
	bool eof; // stdin is a closed pipe or file, stop reading
	bool tty;
	struct termios saved_termios;
	int saved_flags;
} console;

void console_open(void) {
	if (console.open) return;

	console.tty = isatty(STDIN_FILENO);
	if (console.tty) {
		if (tcgetattr(STDIN_FILENO, &console.saved_termios) != 0) {
			warning("Console: can't read terminal settings");
			console.eof = true;
			return;
		}
		struct termios raw = console.saved_termios;
		raw.c_lflag &= ~(ICANON | ECHO); // byte at a time, firmware echoes
		raw.c_cc[VMIN] = 0; // read() returns at once, even with no data
		raw.c_cc[VTIME] = 0;
		tcsetattr(STDIN_FILENO, TCSANOW, &raw);
	} else {
		console.saved_flags = fcntl(STDIN_FILENO, F_GETFL);
		if (console.saved_flags != -1)
			fcntl(STDIN_FILENO, F_SETFL, console.saved_flags | O_NONBLOCK);
	}

	console.open = true;
	atexit(console_close); // error() exits without going through cleanup
}

void console_close(void) {
	if (!console.open) return;
	console.open = false;

	if (console.tty)
		tcsetattr(STDIN_FILENO, TCSANOW, &console.saved_termios);
	else if (console.saved_flags != -1)
		fcntl(STDIN_FILENO, F_SETFL, console.saved_flags);
}

size_t console_read(uint8_t* buffer, const size_t size) {
	if (!console.open || console.eof || size == 0) return 0;

	const ssize_t count = read(STDIN_FILENO, buffer, size);
	if (count > 0) return (size_t)count;
	// raw terminals report "no data" as 0, pipes and files mean end of input
	if (count == 0 && !console.tty) console.eof = true;
	if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
		console.eof = true;
	return 0;
}

#endif
