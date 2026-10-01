// Syntax error: a body that starts with '*' after a condition without parentheses (pointers.m)
// @error 5: the 'if' condition is 'p != null *p', and a statement can't start with '='

let reset(p: *mut UWord): Void {
    if p != null *p = 0
}
