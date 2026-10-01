// For main.m: exports under other names, and imports a.m, which imports
// this file.
import { pong } from "a.m"

let helper(): Word {
    return 2
}

let mix(a: Word, b: Word): Word {
    return a + b
}

let colorGreen(): Word {
    return 4
}

let ping(n: Word): Word {
    if n == 0 return 2
    return pong(n - 1) + 1
}

export { helper as bValue, mix as combine, colorGreen as green, ping }
