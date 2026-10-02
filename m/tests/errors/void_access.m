// Error: nothing can be read or written through *Void
// @error 13: 'p' is '*Void': nothing can be read or written through it
// @error 14: 'p' is '*Void' and can't be indexed
// @error 15: 'q' is '*mut Void', which has no fields
// @error 16: 'q' is '*mut Void': nothing can be read or written through it

type Pair { a: UWord, b: UWord }

let main(argc: UWord, argv: *UByte[]): Word {
    let mut pair: Pair = { .a = 1 }
    let p: *Void = &pair
    let q: *mut Void = &mut pair
    let x: UWord = *p
    let y: UByte = p[0]
    let z: UWord = q.a
    { *q = 0 }
    if x + y as UWord + z != 0 return 1
    return 0
}
