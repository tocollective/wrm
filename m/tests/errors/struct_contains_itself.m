// Error: order.m: 'Loop' contains itself
// @error 4: 'Loop' contains itself

type Loop {
    inner: Loop,
}

let main(argc: UWord, argv: *UByte[]): Word {
    if sizeof(Loop) == 0 return 1
    return 0
}
