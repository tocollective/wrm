// [13] Real-time clock: the date and time from the host, in UTC and in
// local time, then an alarm at the next second that wakes the CPU from
// WFI.

import { pic, rtc, IRQ_RTC, RTC_ARMED, RTC_ALARM, CR_CYCLE } from "../defs.m"
import { puts, putc, strlen, pad, printDec, show } from "../lib.m"

let NAME_WIDTH: UWord = 24              // as show() in lib.m
let SECONDS_PER_DAY: UWord = 86400
let WEEKDAYS: *UByte = "ThuFriSatSunMonTueWed"   // from 1970-01-01, a Thursday

let demoRtc(): Void {
    puts("\n[13] real-time clock\n")

    // reading SECONDS_LO latches the time, so it goes first; SECONDS_HI is
    // 0 until 2106, so the low half is enough here
    let seconds: UWord = rtc.secondsLo
    let offset: UWord = rtc.utcOffset
    label("UTC")
    printTime(seconds)
    puts("\n")
    label("local time")
    printTime(seconds + offset)         // wraps for a negative offset
    puts(" UTC")
    printOffset(offset)
    puts("\n")

    // WFI wakes up once the line is asserted even with interrupts off, so
    // the CPU sleeps until the alarm goes off, with no handler
    let cycles: UWord = mfcr(CR_CYCLE)
    rtc.alarmHi = 0
    rtc.alarmLo = rtc.secondsLo + 1
    rtc.control = RTC_ARMED
    pic.enable = 1 << IRQ_RTC
    while rtc.status == 0 wfi()
    show("alarm after, cycles", mfcr(CR_CYCLE) - cycles)
    rtc.status = RTC_ALARM              // drops the line
    pic.enable = 0
    label("alarm went off at")
    printTime(rtc.secondsLo)
    puts(" UTC\n")
}

/// "name" padded to the column of show()'s values, then "= ".
let label(name: *UByte): Void {
    puts(name)
    let width: UWord = strlen(name)
    if width < NAME_WIDTH pad(NAME_WIDTH - width)
    puts("= ")
}

/// Writes v as two decimal digits.
let print2(v: UWord): Void {
    putc('0' + (v / 10 % 10) as UByte)
    putc('0' + (v % 10) as UByte)
}

/// Writes t, seconds since 1970-01-01, as "Thu 2026-10-02 06:27:39".
let printTime(t: UWord): Void {
    let days: UWord = t / SECONDS_PER_DAY
    let secs: UWord = t % SECONDS_PER_DAY

    // the date from the days, counting years from March 1, so that the
    // leap day comes last (H. Hinnant's civil_from_days)
    let z: UWord = days + 719468        // days since 0000-03-01
    let era: UWord = z / 146097         // 400-year cycles
    let doe: UWord = z - era * 146097   // day of the cycle, 0-146096
    let yoe: UWord = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy: UWord = doe - (365 * yoe + yoe / 4 - yoe / 100)    // 0-365
    let mp: UWord = (5 * doy + 2) / 153 // month from March, 0-11
    let day: UWord = doy - (153 * mp + 2) / 5 + 1
    let mut month: UWord = mp + 3
    let mut year: UWord = era * 400 + yoe
    if mp >= 10 {                       // January and February
        month = mp - 9
        year++
    }

    let weekday: UWord = days % 7 * 3
    for i: UWord in 0..3 putc(WEEKDAYS[weekday + i])
    putc(' ')
    printDec(year)
    putc('-')
    print2(month)
    putc('-')
    print2(day)
    putc(' ')
    print2(secs / 3600)
    putc(':')
    print2(secs / 60 % 60)
    putc(':')
    print2(secs % 60)
}

/// Writes a signed offset in seconds as "+10:00".
let printOffset(offset: UWord): Void {
    let mut n: UWord = offset
    if ((offset as Word) < 0) {
        putc('-')
        n = 0 - offset
    } else {
        putc('+')
    }
    print2(n / 3600)
    putc(':')
    print2(n / 60 % 60)
}

export { demoRtc }
