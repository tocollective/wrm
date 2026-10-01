// Error: pointers.m: &mut of a 'let'
// @error 12: 'red' is not 'let mut'

type Color { r: UByte, g: UByte, b: UByte }

let clear(c: *mut Color): Void {
    *c = {}
}

let main(argc: UWord, argv: *UByte[]): Word {
    let red: Color = { .r = 0xFF }
    clear(&mut red)
    return 0
}
