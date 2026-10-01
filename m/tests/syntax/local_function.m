// Syntax error: functions only at the top level
// @error 5: functions are declared only at the top level

let main(argc: UWord, argv: *UByte[]): Word {
    let inner(): Void {}
    return 0
}
