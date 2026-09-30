#ifndef WRM_UART_H
#define WRM_UART_H
#include "common.h"

#include "devices/pic.h"

#define UART_RX_FIFO_SIZE 64

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define UART_REG_DATA 0x00 // W: transmit a byte, R: pop a received byte
#define UART_REG_STATUS 0x04 // R
#define UART_REG_CONTROL 0x08 // W

#define UART_STATUS_RX_READY 0x01 // RX FIFO is not empty
#define UART_STATUS_TX_READY 0x02 // always set: TX never blocks
#define UART_STATUS_RX_OVERFLOW 0x04 // bytes were dropped, cleared on read

#define UART_CONTROL_RX_FLUSH 0x01 // drop all received bytes

// Serial port. TX goes straight to the host stdout.
// IRQ line is asserted while the RX FIFO is not empty.
typedef struct uart {
	pic_t* pic;
	uint8_t irq;
	uint8_t rx_fifo[UART_RX_FIFO_SIZE];
	uint8_t rx_head; // next byte to read
	uint8_t rx_count;
	bool rx_overflow;
} uart_t;

uart_t* uart_create(pic_t* pic, const uint8_t irq);
void uart_destroy(uart_t* uart);

void uart_reset(uart_t* uart);
// host side: queue a received byte
void uart_receive(uart_t* uart, const uint8_t byte);
// host side: bytes the RX FIFO can take before it overflows
uint8_t uart_rx_space(const uart_t* uart);

// bus side: offset is relative to the device base; return true on bus error
bool uart_read(uart_t* uart, const uint32_t offset, const uint8_t size,
			   uint32_t* value);
bool uart_write(uart_t* uart, const uint32_t offset, const uint8_t size,
				const uint32_t value);

#endif // WRM_UART_H
