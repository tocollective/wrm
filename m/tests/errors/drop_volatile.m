// Error: mmio.m: dropping 'volatile' needs 'as'
// @error 9: it would drop 'volatile'

type UartRegs { data: UWord, status: UWord, control: UWord }

let uart: *volatile mut UartRegs = 0xFD00_2000 as *volatile mut UartRegs

let main(argc: UWord, argv: *UByte[]): Word {
    let plain: *mut UartRegs = uart
    plain.data = 1
    return 0
}
