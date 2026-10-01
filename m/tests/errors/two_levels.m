// Error: pointers.m: '.' dereferences one level
// @error 7: '.' goes through one pointer only

type Color { r: UByte, g: UByte, b: UByte }

let red(pp: **Color): UByte {
    return pp.r
}

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Color = {}
    let p: *Color = &c
    if red(&p) == 0 return 1
    return 0
}
