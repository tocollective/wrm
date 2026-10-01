// Error: pointers.m: &red is *Color
// @error 12: '*Color' can't become '*mut Color' without 'as'

type Color { r: UByte, g: UByte, b: UByte }

let clear(c: *mut Color): Void {
    *c = {}
}

let main(argc: UWord, argv: *UByte[]): Word {
    let red: Color = { .r = 0xFF }
    clear(&red)
    return 0
}
