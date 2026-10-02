// Type error: directly written non-ASCII characters are UWord
// @error 4: expected 'UByte', found 'UWord'

let C: UByte = 'é'

let main(argc: UWord, argv: *UByte[]): Word { return 0 }
