// Error: pointers.m: writing a field needs *mut
// @error 7: 'c' is '*Color': writing through it needs '*mut Color'

type Color { r: UByte, g: UByte, b: UByte }

let clear(c: *Color): Void {
    c.r = 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Color = {}
    clear(&c)
    return 0
}
