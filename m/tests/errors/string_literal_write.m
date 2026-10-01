// Error: pointers.m: string literals are read-only
// @error 6: 'hello' is '*UByte': writing through it needs '*mut UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let hello: *UByte = "Hello"
    hello[0] = 'J'
    return 0
}
