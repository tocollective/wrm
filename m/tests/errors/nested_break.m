// Error: a nested function is a function of its own: 'break' doesn't leave
// the loop of the function around
// @error 7: 'break' outside a loop or 'switch'

let main(argc: UWord, argv: *UByte[]): Word {
    while true {
        let stop(): Void { break }
        stop()
    }
}
