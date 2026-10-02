// Error: *Void becomes a typed pointer only with 'as'
// @error 7: expected '*UWord', found '*Void'; '*Void' becomes another type only with 'as'

let main(argc: UWord, argv: *UByte[]): Word {
    let n: UWord = 7
    let any: *Void = &n
    let p: *UWord = any
    let q: *UWord = any as *UWord
    if *p != *q return 1
    return 0
}
