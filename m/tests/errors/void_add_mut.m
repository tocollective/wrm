// Error: becoming *Void can't add the right to write
// @error 6: '*UWord' can't become '*mut Void' without 'as': it would allow writing

let main(argc: UWord, argv: *UByte[]): Word {
    let n: UWord = 7
    let w: *mut Void = &n
    if w == null return 1
    return 0
}
