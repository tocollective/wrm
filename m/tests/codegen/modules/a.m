// For main.m. 'helper' is also declared in b.m and main.m: local names
// don't clash.
import { ping } from "b.m"

enum Dir: UByte { Up, Down }

let helper(): Word {
    return 1
}

let value(): Word {
    return helper()
}

let pong(n: Word): Word {
    if n == 0 return 0
    return ping(n - 1) + 1
}

export { value, Dir, pong }
