// Error: pointers.m: writing needs *mut
// @error 5: 'p' is '*UWord': writing through it needs '*mut UWord'

let get(p: *UWord): UWord {
    *p = 0
    return *p
}

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord = 1
    let y: UWord = get(&x)
    if y == 0 return 1
    return 0
}
