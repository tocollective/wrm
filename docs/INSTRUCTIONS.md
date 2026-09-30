# WRM.081632 Instructions

All instructions are 32 bits wide, little-endian and must be 4-byte aligned.
The opcode is always the lowest byte.

## Registers

- `r0`–`r31` — 32-bit general purpose registers, `r0` always reads as zero.
- `pc` — program counter, reset value `0xFE000000` (start of ROM).
- `cr0`–`cr3` — control registers, see [Interrupts](#interrupts).

## Formats

```
        31              18 17     13 12      8 7        0
R-type  |  reserved | rs2 |   rs1   |   rd    |  opcode  |
I-type  |      imm14      |   rs1   |   rd    |  opcode  |
U-type  |           imm19           |   rd    |  opcode  |
N-type  |              reserved               |  opcode  |
```

Field positions: `opcode` [7:0], `rd` [12:8], `rs1` [17:13], `rs2` [22:18],
`imm14` [31:18], `imm19` [31:13]. Reserved bits should be zero.

`imm14` is sign-extended, except for `ANDI`, `ORI`, `XORI`, `SHLI`, `SHRI`
and `SARI`, where it is zero-extended. Shift amounts use the low 5 bits.

## Opcodes

### System

| Opcode | Mnemonic        | Format | Operation                              |
|--------|-----------------|--------|----------------------------------------|
| `0x00` | `HLT`           | N      | halt the CPU                           |
| `0x01` | `NOP`           | N      | do nothing                             |
| `0x02` | `WFI`           | N      | wait for interrupt                     |
| `0x03` | `IRET`          | N      | `pc = EPC`, `IE = PIE`                 |
| `0x04` | `MFCR rd, cr`   | I      | `rd = cr[imm14]`                       |
| `0x05` | `MTCR cr, rs1`  | I      | `cr[imm14] = rs1` (`rd` is reserved)   |

`MFCR`/`MTCR` with a control register number that doesn't exist is an
illegal instruction.

### Register ALU

| Opcode | Mnemonic           | Operation                       |
|--------|--------------------|---------------------------------|
| `0x10` | `ADD rd, rs1, rs2` | `rd = rs1 + rs2`                |
| `0x11` | `SUB rd, rs1, rs2` | `rd = rs1 - rs2`                |
| `0x12` | `AND rd, rs1, rs2` | `rd = rs1 & rs2`                |
| `0x13` | `OR rd, rs1, rs2`  | `rd = rs1 \| rs2`               |
| `0x14` | `XOR rd, rs1, rs2` | `rd = rs1 ^ rs2`                |
| `0x15` | `SHL rd, rs1, rs2` | `rd = rs1 << rs2`               |
| `0x16` | `SHR rd, rs1, rs2` | `rd = rs1 >> rs2` (logical)     |
| `0x17` | `SAR rd, rs1, rs2` | `rd = rs1 >> rs2` (arithmetic)  |
| `0x18` | `SLT rd, rs1, rs2` | `rd = rs1 < rs2` (signed)       |
| `0x19` | `SLTU rd, rs1, rs2`| `rd = rs1 < rs2` (unsigned)     |
| `0x1A` | `MUL rd, rs1, rs2` | `rd = rs1 * rs2` (low 32 bits)  |
| `0x1B` | `DIV rd, rs1, rs2` | `rd = rs1 / rs2` (signed)       |
| `0x1C` | `DIVU rd, rs1, rs2`| `rd = rs1 / rs2` (unsigned)     |
| `0x1D` | `REM rd, rs1, rs2` | `rd = rs1 % rs2` (signed)       |
| `0x1E` | `REMU rd, rs1, rs2`| `rd = rs1 % rs2` (unsigned)     |

Division by zero does not trap: `DIV`/`DIVU` return `0xFFFFFFFF`,
`REM`/`REMU` return `rs1`. `DIV 0x80000000, -1` returns `0x80000000`,
the matching `REM` returns `0`.

### Immediate ALU

The low nibble matches the register form.

| Opcode | Mnemonic               | Operation                      |
|--------|------------------------|--------------------------------|
| `0x20` | `ADDI rd, rs1, imm`    | `rd = rs1 + imm`               |
| `0x22` | `ANDI rd, rs1, imm`    | `rd = rs1 & imm`               |
| `0x23` | `ORI rd, rs1, imm`     | `rd = rs1 \| imm`              |
| `0x24` | `XORI rd, rs1, imm`    | `rd = rs1 ^ imm`               |
| `0x25` | `SHLI rd, rs1, imm`    | `rd = rs1 << imm`              |
| `0x26` | `SHRI rd, rs1, imm`    | `rd = rs1 >> imm` (logical)    |
| `0x27` | `SARI rd, rs1, imm`    | `rd = rs1 >> imm` (arithmetic) |
| `0x28` | `SLTI rd, rs1, imm`    | `rd = rs1 < imm` (signed)      |
| `0x29` | `SLTIU rd, rs1, imm`   | `rd = rs1 < imm` (unsigned)    |

### Upper immediate

| Opcode | Mnemonic        | Operation              |
|--------|-----------------|------------------------|
| `0x30` | `LUI rd, imm`   | `rd = imm19 << 13`     |
| `0x31` | `AUIPC rd, imm` | `rd = pc + (imm19 << 13)`|

A full 32-bit constant is loaded with `LUI rd, hi19` + `ORI rd, rd, lo13`.

### Loads and stores

Address is `rs1 + imm14`. Accesses must be naturally aligned.
Stores use `rd` as the source register.

| Opcode | Mnemonic            | Operation                          |
|--------|---------------------|------------------------------------|
| `0x40` | `LB rd, imm(rs1)`   | load byte, sign-extend             |
| `0x41` | `LBU rd, imm(rs1)`  | load byte, zero-extend             |
| `0x42` | `LH rd, imm(rs1)`   | load half-word, sign-extend        |
| `0x43` | `LHU rd, imm(rs1)`  | load half-word, zero-extend        |
| `0x44` | `LW rd, imm(rs1)`   | load word                          |
| `0x48` | `SB rd, imm(rs1)`   | store low byte of `rd`             |
| `0x49` | `SH rd, imm(rs1)`   | store low half-word of `rd`        |
| `0x4A` | `SW rd, imm(rs1)`   | store `rd`                         |

### Branches

Compare `rd` with `rs1`; if true, `pc = pc + (imm14 << 2)`, where `pc` is the
address of the branch itself (range ±32KB).

| Opcode | Mnemonic               | Condition                 |
|--------|------------------------|---------------------------|
| `0x50` | `BEQ rd, rs1, off`     | `rd == rs1`               |
| `0x51` | `BNE rd, rs1, off`     | `rd != rs1`               |
| `0x52` | `BLT rd, rs1, off`     | `rd < rs1` (signed)       |
| `0x53` | `BGE rd, rs1, off`     | `rd >= rs1` (signed)      |
| `0x54` | `BLTU rd, rs1, off`    | `rd < rs1` (unsigned)     |
| `0x55` | `BGEU rd, rs1, off`    | `rd >= rs1` (unsigned)    |

### Jumps

| Opcode | Mnemonic              | Format | Operation                                  |
|--------|-----------------------|--------|--------------------------------------------|
| `0x60` | `JAL rd, off`         | U      | `rd = pc + 4; pc = pc + (imm19 << 2)` (±1MB) |
| `0x61` | `JALR rd, rs1, imm`   | I      | `rd = pc + 4; pc = (rs1 + imm14) & ~3`     |

`JAL r0, off` is an unconditional jump, `JALR r0, r31, 0` is a return.

## Interrupts

### Control registers

| Number | Name      | Reset | Description                                  |
|--------|-----------|-------|----------------------------------------------|
| `0`    | `STATUS`  | `0`   | bit 0 = `IE` (interrupts enabled), bit 1 = `PIE` (previous `IE`); other bits read as zero |
| `1`    | `EPC`     | `0`   | address `IRET` returns to                    |
| `2`    | `IVEC`    | `0`   | interrupt handler address                    |
| `3`    | `SCRATCH` | `0`   | free for software, e.g. to save a register in the handler |

### Taking an interrupt

The CPU has one level-triggered IRQ input driven by the PIC (see
[SPECIFICATION.md](SPECIFICATION.md)). When it is asserted and `IE` is set,
the CPU finishes the current instruction and then:

1. `EPC` = address of the next instruction that has not executed yet,
2. `PIE` = `IE`, `IE` = 0,
3. `pc` = `IVEC`.

The handler finds the source by reading the PIC `CLAIM` register and must
clear the condition in the device before `IRET`, otherwise the line stays
asserted and the interrupt is taken again right after `IRET`.

A handler that sets `IE` to allow nested interrupts has to save `EPC` first
and clear `IE` again before restoring `EPC` and executing `IRET`.

### WFI

`WFI` stops fetching until the IRQ line is asserted. If `IE` is set, the
interrupt is taken with `EPC` pointing after the `WFI`; otherwise execution
simply continues with the next instruction.

### Control register access

`MFCR`, `MTCR` and `IRET` wait until all older instructions have finished,
so they always see the effect of preceding `MTCR`s. `MTCR` takes effect when
it completes: an interrupt can arrive right after `MTCR STATUS` sets `IE`,
but never after an `MTCR` that clears it.

## Faults

Illegal opcode, misaligned fetch/load/store, access to unmapped memory and
writes to ROM halt the CPU. `pc` is left pointing at the faulting instruction.
Faults are not interrupts: they can't be handled and ignore `IE`.
