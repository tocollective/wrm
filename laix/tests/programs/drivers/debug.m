// UART-only formatting regression; no kernel, screen or disk initialization.
import { debugPrint } from "../../../src/drivers/debug_uart.m"

let forward(text: *UByte, args: ...): Void { debugPrint(text, args) }

let main(argc: UWord, argv: *UByte[]): Word {
    debugPrint("hex=$h $h $h\n", 0, 0x1001, 0xFFFFFFFF)
    debugPrint("int=$i $i uint=$u\n", -42, -2147483648, 0xFFFFFFFF)
    debugPrint("r$02i=$h [$5i] [$05i]\n", 7, 0x42, -42, -42)
    debugPrint("text=$s null=$s escaped=$$\n", "raw $h", null)
    debugPrint("unknown=$x missing=$02i trailing=$\n")
    forward("forward=$s/$h/$i\n", "ok", 0x42, -42)
    return 0
}

// @output "hex=00000000 00001001 FFFFFFFF\n"
// @output "int=-42 -2147483648 uint=4294967295\n"
// @output "r07=00000042 [  -42] [-0042]\n"
// @output "text=raw $h null=(null) escaped=$\n"
// @output "unknown=$x missing=$02i trailing=$\n"
// @output "forward=ok/00000042/-42\n"
// @exit 0
