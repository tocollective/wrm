#include "devices/rtc.h"

#include <SDL3/SDL_time.h>
#include <SDL3/SDL_timer.h>

// the time in ns since the epoch: the host's wall clock (0 if unknown or
// before the epoch), or the virtual time
static uint64_t rtc_now_ns(const rtc_t* rtc) {
	if (rtc->virtual_ticks) {
		const uint64_t ticks = *rtc->virtual_ticks;
		const uint64_t seconds = ticks / rtc->frequency;
		const uint64_t rest = ticks % rtc->frequency; // < 2^32
		return (rtc->virtual_epoch + seconds) * SDL_NS_PER_SECOND
			 + rest * SDL_NS_PER_SECOND / rtc->frequency;
	}
	SDL_Time now = 0;
	if (!SDL_GetCurrentTime(&now) || now < 0) return 0;
	return (uint64_t)now;
}

static void rtc_update_irq(rtc_t* rtc) {
	pic_set_line(rtc->pic, rtc->irq, rtc->fired);
}

static void rtc_latch(rtc_t* rtc) {
	const uint64_t now = rtc_now_ns(rtc);
	rtc->seconds = now / SDL_NS_PER_SECOND;
	rtc->nanoseconds = (uint32_t)(now % SDL_NS_PER_SECOND);

	SDL_DateTime local;
	rtc->utc_offset = 0;
	if (!rtc->virtual_ticks
		&& SDL_TimeToDateTime((SDL_Time)now, &local, true))
		rtc->utc_offset = local.utc_offset;
}

// one-shot: the alarm goes off once the time reaches ALARM
static void rtc_check_alarm(rtc_t* rtc) {
	if (!(rtc->control & RTC_CONTROL_ALARM)) return;
	if (rtc_now_ns(rtc) / SDL_NS_PER_SECOND < rtc->alarm) return;
	rtc->control &= ~RTC_CONTROL_ALARM;
	rtc->fired = true;
	rtc_update_irq(rtc);
}

rtc_t* rtc_create(pic_t* pic, const uint8_t irq, const uint32_t frequency) {
	rtc_t* rtc = (rtc_t*)calloc(1, sizeof(rtc_t));
	if (!rtc) error("Failed to allocate RTC!");
	rtc->pic = pic;
	rtc->irq = irq;
	rtc->frequency = frequency ? frequency : 1;
	rtc->period = frequency / RTC_CHECKS_PER_SECOND;
	if (rtc->period == 0) rtc->period = 1;
	rtc_reset(rtc);
	return rtc;
}

void rtc_destroy(rtc_t* rtc) {
	if (!rtc) return;
	free(rtc);
	rtc = NULL;
}

void rtc_reset(rtc_t* rtc) {
	if (!rtc) return;
	rtc->ticks = 0;
	rtc->alarm = 0;
	rtc->control = 0;
	rtc->fired = false;
	rtc_latch(rtc); // SECONDS_HI reads sensibly before the first latch
	rtc_update_irq(rtc);
}

void rtc_set_virtual(rtc_t* rtc, const uint64_t* ticks, const uint64_t epoch) {
	if (!rtc) return;
	rtc->virtual_ticks = ticks;
	rtc->virtual_epoch = epoch;
	rtc_latch(rtc);
}

// The clock is only asked while the alarm is armed, every period ticks.
void rtc_run(rtc_t* rtc, uint64_t ticks) {
	while (ticks > 0 && (rtc->control & RTC_CONTROL_ALARM)) {
		const uint64_t due = rtc->period - rtc->ticks;
		if (ticks < due) {
			rtc->ticks += (uint32_t)ticks;
			return;
		}
		ticks -= due;
		rtc->ticks = 0;
		rtc_check_alarm(rtc);
	}
}

uint64_t rtc_next_event(const rtc_t* rtc) {
	if (!(rtc->control & RTC_CONTROL_ALARM)) return TICKS_NEVER;
	return rtc->period - rtc->ticks;
}

bool rtc_read(rtc_t* rtc, const uint32_t offset, const uint8_t size,
			  uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case RTC_REG_SECONDS_LO:
			rtc_latch(rtc);
			*value = (uint32_t)rtc->seconds;
			return false;
		case RTC_REG_SECONDS_HI:
			*value = (uint32_t)(rtc->seconds >> 32);
			return false;
		case RTC_REG_NANOSECONDS:
			*value = rtc->nanoseconds;
			return false;
		case RTC_REG_UTC_OFFSET:
			*value = (uint32_t)rtc->utc_offset;
			return false;
		case RTC_REG_ALARM_LO:
			*value = (uint32_t)rtc->alarm;
			return false;
		case RTC_REG_ALARM_HI:
			*value = (uint32_t)(rtc->alarm >> 32);
			return false;
		case RTC_REG_CONTROL:
			*value = rtc->control;
			return false;
		case RTC_REG_STATUS:
			*value = rtc->fired ? RTC_STATUS_ALARM : 0;
			return false;
	}
	return true;
}

bool rtc_write(rtc_t* rtc, const uint32_t offset, const uint8_t size,
			   const uint32_t value) {
	(void)size;
	switch (offset) {
		case RTC_REG_SECONDS_LO:
		case RTC_REG_SECONDS_HI:
		case RTC_REG_NANOSECONDS:
		case RTC_REG_UTC_OFFSET:
			return false; // read-only, writes are ignored
		case RTC_REG_ALARM_LO:
			rtc->alarm = (rtc->alarm & 0xFFFFFFFF00000000ULL) | value;
			return false;
		case RTC_REG_ALARM_HI:
			rtc->alarm = (rtc->alarm & 0xFFFFFFFFULL) | (uint64_t)value << 32;
			return false;
		case RTC_REG_CONTROL:
			rtc->control = value & RTC_CONTROL_MASK;
			rtc->ticks = 0;
			rtc_check_alarm(rtc); // an alarm in the past goes off at once
			return false;
		case RTC_REG_STATUS:
			if (value & RTC_STATUS_ALARM) {
				rtc->fired = false;
				rtc_update_irq(rtc);
			}
			return false;
	}
	return true;
}
