// Error: an array doesn't become *Void by itself, even as an argument;
// '&buf' does
// @error 12: expected '*mut Void', found 'UByte[4]'

let clear(p: *mut Void, n: UWord): Void {
    let bytes: *mut UByte = p as *mut UByte
    for i: UWord in 0..n bytes[i] = 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    let mut buf: UByte[4] = [1, 2, 3, 4]
    clear(buf, 4)
    clear(&mut buf, 4)
    return buf[0] as Word
}
