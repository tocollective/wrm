// Error: globals.m: 'ticks' is 'let mut'
// @error 5: 'ticks' is 'let mut': a global initializer can use only constants

let mut ticks: UWord
let START: UWord = ticks

let main(argc: UWord, argv: *UByte[]): Word {
    ticks = START
    return 0
}
