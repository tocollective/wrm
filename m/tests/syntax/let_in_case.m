// Syntax error: 'let' right inside a 'case' (switch.m)
// @error 7: 'let' can't go right inside a 'case'

let half(n: UWord): UWord {
    switch n {
        case 0:
            let h: UWord = n / 2
            return h
    }
    return n
}
