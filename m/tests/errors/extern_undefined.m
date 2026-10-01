// Error: an 'extern' that nothing defines (a linker error)
// @error 4: nothing defines 'extern' 'nowhere'

extern let nowhere(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    nowhere()
    return 0
}
