// Error: arrays.m: only a 'let mut' array goes to 'mut T[]'
// @error 10: 'copy' is not 'let mut', so it can't be passed as 'mut UByte[]'

let fill(buf: mut UByte[], n: UWord, value: UByte): Void {
    for i: UWord in 0..n buf[i] = value
}

let main(argc: UWord, argv: *UByte[]): Word {
    let copy: UByte[16] = []
    fill(copy, 16, 0)
    return 0
}
