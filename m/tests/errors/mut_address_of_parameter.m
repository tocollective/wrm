// Error: '&mut' of a parameter
// @error 9: 'n' is a parameter

let inc(p: *mut UWord): Void {
    *p = *p + 1
}

let f(n: UWord): Void {
    inc(&mut n)
}

let main(argc: UWord, argv: *UByte[]): Word {
    f(1)
    return 0
}
