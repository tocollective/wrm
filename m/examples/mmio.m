// Device registers (MMIO) are accessed through a 'volatile' pointer:
//   *volatile T       read-only
//   *volatile mut T   read and write
//
// Every read and write through such a pointer happens exactly once, in the
// order of the source, with the width of the field's type. The compiler does
// not drop, merge or reorder them.
//
// 'volatile' goes through '.' and '&': '&uart.status' is '*volatile UWord'.
// It is added implicitly ('*mut T' goes where '*volatile mut T' is expected),
// but removed only with 'as'.

type UartRegs {
    data:    UWord,  // 0x00  W: transmit the low byte, R: pop an RX byte
    status:  UWord,  // 0x04  R: bit 0 RX ready, bit 1 TX ready, bit 2 RX overflow
    control: UWord,  // 0x08  W: bit 0 flushes the RX FIFO
}

let UART_RX_READY: UWord    = 1 << 0
let UART_TX_READY: UWord    = 1 << 1
let UART_RX_OVERFLOW: UWord = 1 << 2
let UART_FLUSH_RX: UWord    = 1 << 0

let uart: *volatile mut UartRegs = 0xFD00_2000 as *volatile mut UartRegs

let putc(c: UByte): Void {
    // STATUS is read again on every iteration: the read is not moved out
    // of the loop, even though nothing in the loop writes to it
    while uart.status & UART_TX_READY == 0 {}
    uart.data = c as UWord
}

let getc(): UByte {
    while uart.status & UART_RX_READY == 0 {}
    return uart.data as UByte  // this read pops the byte from the FIFO
}

let print(s: *UByte): Void {
    let mut i: UWord = 0
    while s[i] != 0 {
        putc(s[i])
        i++
    }
}

let readTwo(): UWord {
    // Two reads stay two reads: each pops its own byte
    let first: UWord = uart.data
    let second: UWord = uart.data
    return first << 8 | second
}

let overflowed(): Bool {
    // Reading STATUS clears the overflow bit, so read it once and keep it
    let status: UWord = uart.status
    return status & UART_RX_OVERFLOW != 0
}

let flush(): Void {
    uart.control = UART_FLUSH_RX
}

let pointerToField(): UWord {
    // 'volatile' goes through '&'
    let p: *volatile UWord = &uart.status
    return *p
}

let snapshot(): UartRegs {
    // A whole-struct copy reads the fields one by one, in declaration
    // order, each with its own width
    let regs: UartRegs = *uart
    return regs
}

// Writes every byte exactly once, in order. Works for a device and,
// because 'volatile' is added implicitly, for ordinary memory too.
let copyToDevice(dst: *volatile mut UByte, src: *UByte, n: UWord): Void {
    for i: UWord in 0..n dst[i] = src[i]
}

let copies(): Void {
    let mut buf: UByte[4]
    copyToDevice(&mut buf[0], "abc", 4)  // *mut UByte -> *volatile mut UByte
}

// Compile error: dropping 'volatile' needs 'as'
//     let plain: *mut UartRegs = uart
// With 'as' it compiles, but accesses through 'plain' are ordinary memory
// accesses and may be optimized away:
//     let plain: *mut UartRegs = uart as *mut UartRegs

let main(argc: UWord, argv: *UByte[]): Word {
    flush()
    copies()
    print("Hello, UART!\n")
    let c: UByte = getc()
    putc(c)  // echo
    if overflowed() print("overflow\n")
    return 0
}

// Test directives (m/tests/run.py)
// @input "Q"
// @output "Hello, UART!\nQ"
// @exit 0
