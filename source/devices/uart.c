#include "devices/uart.h"

#include <stdio.h>

static void uart_update_irq(uart_t* uart) {
	pic_set_line(uart->pic, uart->irq, uart->rx_count > 0);
}

uart_t* uart_create(pic_t* pic, const uint8_t irq) {
	uart_t* uart = (uart_t*)calloc(1, sizeof(uart_t));
	if (!uart) error("Failed to allocate UART!");
	uart->pic = pic;
	uart->irq = irq;
	uart_reset(uart);
	return uart;
}

void uart_destroy(uart_t* uart) {
	if (!uart) return;
	free(uart);
	uart = NULL;
}

void uart_reset(uart_t* uart) {
	if (!uart) return;
	uart->rx_head = 0;
	uart->rx_count = 0;
	uart->rx_overflow = false;
	uart_update_irq(uart);
}

void uart_receive(uart_t* uart, const uint8_t byte) {
	if (!uart) return;
	if (uart->rx_count == UART_RX_FIFO_SIZE) {
		uart->rx_overflow = true;
		return;
	}

	const uint8_t tail = (uart->rx_head + uart->rx_count) % UART_RX_FIFO_SIZE;
	uart->rx_fifo[tail] = byte;
	uart->rx_count++;
	uart_update_irq(uart);
}

uint8_t uart_rx_space(const uart_t* uart) {
	if (!uart) return 0;
	return UART_RX_FIFO_SIZE - uart->rx_count;
}

static uint8_t uart_pop(uart_t* uart) {
	if (uart->rx_count == 0) return 0;
	const uint8_t byte = uart->rx_fifo[uart->rx_head];
	uart->rx_head = (uart->rx_head + 1) % UART_RX_FIFO_SIZE;
	uart->rx_count--;
	uart_update_irq(uart);
	return byte;
}

static void uart_transmit(const uint8_t byte) {
	fputc(byte, stdout);
	fflush(stdout);
}

bool uart_read(uart_t* uart, const uint32_t offset, const uint8_t size,
			   uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case UART_REG_DATA:
			*value = uart_pop(uart);
			return false;
		case UART_REG_STATUS: {
			uint32_t status = UART_STATUS_TX_READY;
			if (uart->rx_count > 0) status |= UART_STATUS_RX_READY;
			if (uart->rx_overflow) status |= UART_STATUS_RX_OVERFLOW;
			uart->rx_overflow = false;
			*value = status;
			return false;
		}
		case UART_REG_CONTROL:
			*value = 0;
			return false;
	}
	return true;
}

bool uart_write(uart_t* uart, const uint32_t offset, const uint8_t size,
				const uint32_t value) {
	(void)size;
	switch (offset) {
		case UART_REG_DATA:
			uart_transmit(value & 0xFF);
			return false;
		case UART_REG_STATUS:
			return false; // read-only, writes are ignored
		case UART_REG_CONTROL:
			if (value & UART_CONTROL_RX_FLUSH) uart_reset(uart);
			return false;
	}
	return true;
}
