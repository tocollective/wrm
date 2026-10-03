// Warning: a local or a parameter that shadows a local, a parameter or a
// nested function (3.7); shadowing a top-level name is silent
// @warning 13: 'x' shadows the local 'x' at line 11
// @warning 16: 'n' shadows the parameter 'n' at line 10
// @warning 21: 'i' shadows the loop variable 'i' at line 20
// @warning 25: parameter 'helper' shadows the function 'helper' at line 24

let LIMIT: UWord = 10

let f(n: UWord): UWord {
    let x: UWord = n
    if x > 1 {
        let x: UWord = 2
        if x == 2 return 1
    } else {
        let n: UWord = 3
        if n == 3 return 2
    }
    let mut total: UWord = 0
    for i: UWord in 0..LIMIT {
        let i: UWord = 1
        total += i
    }
    let helper(): UWord { return 4 }
    let other(helper: UWord): UWord { return helper }
    let LIMIT: UWord = helper() + other(5)
    return total + LIMIT
}

let main(argc: UWord, argv: *UByte[]): Word {
    return f(argc) as Word
}
