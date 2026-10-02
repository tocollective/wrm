#include "input.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#define INPUT_LINE_SIZE 4096

// Where a line is being read, for the error messages
typedef struct input_parser {
	const char* path;
	int line;
	const char* p;
} input_parser_t;

static void input_fail(const input_parser_t* parser, const char* what) {
	error("%s:%d: %s", parser->path, parser->line, what);
}

static void input_skip_space(input_parser_t* parser) {
	while (*parser->p == ' ' || *parser->p == '\t') parser->p++;
}

// The next word, copied into word; "" at the end of the line.
static void input_word(input_parser_t* parser, char* word, const size_t size) {
	input_skip_space(parser);
	size_t length = 0;
	while (*parser->p && !isspace((unsigned char)*parser->p)) {
		if (length + 1 >= size) input_fail(parser, "word too long");
		word[length++] = *parser->p++;
	}
	word[length] = '\0';
}

static int64_t input_number(input_parser_t* parser, const char* what) {
	char word[32];
	input_word(parser, word, sizeof(word));
	errno = 0;
	char* end = NULL;
	const long long value = strtoll(word, &end, 0);
	if (!word[0] || *end || errno) input_fail(parser, what);
	return value;
}

static bool input_down(input_parser_t* parser) {
	char word[16];
	input_word(parser, word, sizeof(word));
	if (strcmp(word, "down") == 0) return true;
	if (strcmp(word, "up") != 0) input_fail(parser, "expected down or up");
	return false;
}

static int input_hex_digit(const char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

// The rest of the line with its escapes undone; the length goes in event->a.
static void input_text(input_parser_t* parser, input_event_t* event) {
	input_skip_space(parser);
	const size_t size = strlen(parser->p) + 1;
	char* text = malloc(size);
	if (!text) error("Failed to allocate the input script!");
	size_t length = 0;
	for (const char* p = parser->p; *p; p++) {
		if (*p != '\\') {
			text[length++] = *p;
			continue;
		}
		switch (*++p) {
			case 'n':
				text[length++] = '\n';
				break;
			case 'r':
				text[length++] = '\r';
				break;
			case 't':
				text[length++] = '\t';
				break;
			case '\\':
				text[length++] = '\\';
				break;
			case 'x': {
				const int high = input_hex_digit(p[1]);
				const int low = high < 0 ? -1 : input_hex_digit(p[2]);
				if (low < 0) input_fail(parser, "\\x needs two hex digits");
				text[length++] = (char)(high << 4 | low);
				p += 2;
			} break;
			default:
				input_fail(parser, "unknown escape");
		}
	}
	event->text = text;
	event->a = (int32_t)length;
}

// Parses the event after its tick.
static void input_parse_event(input_parser_t* parser, input_event_t* event) {
	char kind[16];
	input_word(parser, kind, sizeof(kind));
	if (strcmp(kind, "key") == 0) {
		event->kind = INPUT_KEY;
		event->a = (int32_t)input_number(parser, "invalid key usage");
		if (event->a <= 0 || event->a > 0xFFFF)
			input_fail(parser, "invalid key usage");
		event->b = input_down(parser);
	} else if (strcmp(kind, "uart") == 0) {
		event->kind = INPUT_UART;
		input_text(parser, event);
		return; // the text is the rest of the line
	} else if (strcmp(kind, "mouse") == 0) {
		event->kind = INPUT_MOUSE;
		event->a = (int32_t)input_number(parser, "invalid motion");
		event->b = (int32_t)input_number(parser, "invalid motion");
	} else if (strcmp(kind, "button") == 0) {
		char name[16];
		input_word(parser, name, sizeof(name));
		event->kind = INPUT_BUTTON;
		if (strcmp(name, "left") == 0)
			event->a = MOUSE_BUTTON_LEFT;
		else if (strcmp(name, "right") == 0)
			event->a = MOUSE_BUTTON_RIGHT;
		else if (strcmp(name, "middle") == 0)
			event->a = MOUSE_BUTTON_MIDDLE;
		else
			input_fail(parser, "expected left, right or middle");
		event->b = input_down(parser);
	} else if (strcmp(kind, "wheel") == 0) {
		event->kind = INPUT_WHEEL;
		event->a = (int32_t)input_number(parser, "invalid wheel steps");
	} else if (strcmp(kind, "power") == 0) {
		event->kind = INPUT_POWER;
	} else {
		input_fail(parser, "unknown event");
	}
	char rest[8];
	input_word(parser, rest, sizeof(rest));
	if (rest[0]) input_fail(parser, "too many fields");
}

input_t* input_load(const char* path) {
	FILE* file = fopen(path, "r");
	if (!file) error("Failed to open the input script %s", path);

	input_t* input = calloc(1, sizeof(input_t));
	if (!input) error("Failed to allocate the input script!");
	size_t capacity = 0;
	uint64_t tick = 0;
	input_parser_t parser = { path, 0, NULL };
	char line[INPUT_LINE_SIZE];
	while (fgets(line, sizeof(line), file)) {
		parser.line++;
		const size_t length = strlen(line);
		if (length + 1 == sizeof(line) && line[length - 1] != '\n')
			input_fail(&parser, "line too long");
		// the line end, a comment and the spaces before them go (a '#' in
		// uart text is \x23, a space at its end \x20)
		size_t end = strcspn(line, "\r\n#");
		while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == '\t'))
			end--;
		line[end] = '\0';
		parser.p = line;
		input_skip_space(&parser);
		if (!*parser.p) continue;

		const bool relative = *parser.p == '+';
		if (relative) parser.p++;
		const int64_t number = input_number(&parser, "invalid tick");
		if (number < 0) input_fail(&parser, "invalid tick");
		const uint64_t at = relative ? tick + (uint64_t)number : (uint64_t)number;
		if (at < tick) input_fail(&parser, "events must come in order");
		tick = at;

		if (input->count == capacity) {
			capacity = capacity ? capacity * 2 : 16;
			input->events =
				realloc(input->events, capacity * sizeof(input_event_t));
			if (!input->events) error("Failed to allocate the input script!");
		}
		input_event_t* event = &input->events[input->count];
		memset(event, 0, sizeof(*event));
		event->tick = tick;
		input_parse_event(&parser, event);
		input->count++;
	}
	fclose(file);
	print("Input script %s: %zu events", path, input->count);
	return input;
}

void input_destroy(input_t* input) {
	if (!input) return;
	for (size_t i = 0; i < input->count; i++) free(input->events[i].text);
	free(input->events);
	free(input);
}

uint64_t input_next_tick(const input_t* input) {
	if (!input || input->next == input->count) return TICKS_NEVER;
	return input->events[input->next].tick;
}

static void input_apply(const input_event_t* event, motherboard_t* mb) {
	switch (event->kind) {
		case INPUT_KEY:
			keyboard_key(mb->keyboard, (uint16_t)event->a, event->b != 0);
			break;
		case INPUT_UART:
			for (int32_t i = 0; i < event->a; i++)
				uart_receive(mb->uart, (uint8_t)event->text[i]);
			break;
		case INPUT_MOUSE:
			mouse_move(mb->mouse, event->a, event->b);
			break;
		case INPUT_BUTTON:
			mouse_button(mb->mouse, (uint32_t)event->a, event->b != 0);
			break;
		case INPUT_WHEEL:
			mouse_wheel(mb->mouse, event->a);
			break;
		case INPUT_POWER:
			power_request_off(mb->power);
			break;
	}
}

void input_feed(input_t* input, const uint64_t tick, motherboard_t* mb) {
	if (!input) return;
	while (input->next < input->count && input->events[input->next].tick <= tick)
		input_apply(&input->events[input->next++], mb);
}

void input_seek(input_t* input, const uint64_t tick) {
	if (!input) return;
	input->next = 0;
	while (input->next < input->count && input->events[input->next].tick < tick)
		input->next++;
}
