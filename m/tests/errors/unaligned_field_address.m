// Error: layout.m: 'length' is not aligned
// @error 7: 'length' is not aligned in packed 'DiskHeader'

packed type DiskHeader { kind: UByte, length: UWord, flags: UHalf }

let f(h: *DiskHeader): *UWord {
    return &h.length
}

let main(argc: UWord, argv: *UByte[]): Word {
    let h: DiskHeader = {}
    if f(&h) == null return 1
    return 0
}
