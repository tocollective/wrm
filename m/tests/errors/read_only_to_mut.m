// Error: pointers.m: *T to *mut T needs 'as'
// @error 9: '*Color' can't become '*mut Color' without 'as'

type Color { r: UByte, g: UByte, b: UByte }

let main(argc: UWord, argv: *UByte[]): Word {
    let mut c: Color = {}
    let r: *Color = &c
    let w2: *mut Color = r
    w2.r = 1
    return 0
}
