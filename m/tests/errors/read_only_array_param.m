// Error: arrays.m: 'buf' is read-only
// @error 5: 'buf' is '*UByte': writing through it needs '*mut UByte'

let clear(buf: UByte[]): Void {
    buf[0] = 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    let b: UByte[4] = []
    clear(b)
    return 0
}
