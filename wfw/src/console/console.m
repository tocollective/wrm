// Screen-only firmware console. UART belongs to booted software and tests.

import { videoInit, conPutc } from "../video/video.m"

let mut screenReady: Bool
let HEX: *UByte = "0123456789ABCDEF"

let consoleInit(): Bool {
    screenReady = videoInit()
    return screenReady
}

let writeChar(c: UByte): Void {
    if screenReady conPutc(c)
}

let write(s: *UByte): Void {
    let mut i: UWord = 0
    while s[i] != 0 {
        writeChar(s[i])
        i++
    }
}

let writeHex(value: UWord): Void {
    write("0x")
    for i: UWord in 8..0 by -1 {
        writeChar(HEX[value >> (4 * (i - 1)) & 15])
    }
}

export { consoleInit, writeChar, write, writeHex }
