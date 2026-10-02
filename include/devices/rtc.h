#ifndef WRM_RTC_H
#define WRM_RTC_H
#include "common.h"

#include "devices/pic.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define RTC_REG_SECONDS_LO 0x00 // R: seconds since 1970-01-01 UTC; latches
#define RTC_REG_SECONDS_HI 0x04 // R: latched high half
#define RTC_REG_NANOSECONDS 0x08 // R: latched, 0-999999999
#define RTC_REG_UTC_OFFSET 0x0C // R: latched, local time - UTC in seconds
#define RTC_REG_ALARM_LO 0x10 // RW: alarm time in seconds, low half
#define RTC_REG_ALARM_HI 0x14 // RW: high half
#define RTC_REG_CONTROL 0x18 // RW
#define RTC_REG_STATUS 0x1C // R, W: 1 clears the bit

#define RTC_CONTROL_ALARM 0x01 // alarm armed, cleared when it goes off
#define RTC_CONTROL_MASK RTC_CONTROL_ALARM

#define RTC_STATUS_ALARM 0x01

// alarm checks per second of clock ticks
#define RTC_CHECKS_PER_SECOND 1000

// Real-time clock: the host's wall clock time and a one-shot alarm.
// IRQ line is asserted while STATUS.ALARM is set.
// With a virtual time (rtc_set_virtual) it counts clock ticks from a fixed
// moment instead, so a run doesn't depend on when or how fast it happens.
typedef struct rtc {
	pic_t* pic;
	uint8_t irq;
	uint32_t frequency; // clock ticks per second
	const uint64_t* virtual_ticks; // NULL = the host's time
	uint64_t virtual_epoch; // seconds since 1970 at tick 0
	uint32_t period; // ticks between alarm checks
	uint32_t ticks; // towards the next check
	uint64_t seconds; // latched by a read of SECONDS_LO
	uint32_t nanoseconds;
	int32_t utc_offset;
	uint64_t alarm;
	uint32_t control;
	bool fired;
} rtc_t;

rtc_t* rtc_create(pic_t* pic, const uint8_t irq, const uint32_t frequency);
void rtc_destroy(rtc_t* rtc);

// clears the alarm; the time keeps following the host's clock
void rtc_reset(rtc_t* rtc);
// From now on the time is epoch seconds after 1970-01-01 UTC plus *ticks
// clock ticks; the UTC offset is 0.
void rtc_set_virtual(rtc_t* rtc, const uint64_t* ticks, const uint64_t epoch);
// Advances the alarm check by that many clock ticks.
void rtc_run(rtc_t* rtc, const uint64_t ticks);
// Ticks until the next alarm check (1 = the next tick) while the alarm is
// armed, TICKS_NEVER otherwise.
uint64_t rtc_next_event(const rtc_t* rtc);

// bus side: offset is relative to the device base; return true on bus error
bool rtc_read(rtc_t* rtc, const uint32_t offset, const uint8_t size,
			  uint32_t* value);
bool rtc_write(rtc_t* rtc, const uint32_t offset, const uint8_t size,
			   const uint32_t value);

#endif // WRM_RTC_H
