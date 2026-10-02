# WRM.081632 Instructions

All instructions are 32 bits wide, little-endian and must be 4-byte aligned.
The opcode is always the lowest byte.

## Registers

- `r0`–`r31` — 32-bit general purpose registers, `r0` always reads as zero.
- `pc` — program counter, reset value `0xFE000000` (start of ROM).
- `cr0`–`cr17` — control registers, see [Control registers](#control-registers).

## Privilege modes

The CPU runs either in **supervisor** or in **user** mode, selected by
`STATUS.UM`. It starts in supervisor mode after reset.

User mode can't:

- execute `HLT`, `WFI`, `IRET`, `MFCR`, `MTCR` and `TLBI` — they raise a
  privileged instruction fault; `MFCR` of the
  [counters](#counters) and `MFCR` and `MTCR` of
  [`FCSR`](#floating-point-environment) are the exceptions,
- access pages without the `U` bit while the MMU is on (page fault).

User code enters the supervisor only through the handler: with `SYSCALL`,
a fault or an interrupt. The supervisor enters user mode by setting
`PUM` and `EPC` and executing `IRET`.

While the MMU is off, user mode has access to all of physical memory, so
the MMU has to be on to protect the supervisor.

## Formats

```
        31              18 17     13 12      8 7        0
R-type  |  reserved | rs2 |   rs1   |   rd    |  opcode  |
I-type  |      imm14      |   rs1   |   rd    |  opcode  |
U-type  |           imm19           |   rd    |  opcode  |
N-type  |              reserved               |  opcode  |
```

Field positions: `opcode` [7:0], `rd` [12:8], `rs1` [17:13], `rs2` [22:18],
`imm14` [31:18], `imm19` [31:13].

Reserved fields must be zero; an instruction with a reserved bit set is an
illegal instruction. They are bits [31:8] of the N-type, bits [31:23] of
the R-type, and the fields the tables below mark as reserved: `rs2` of
`LL` and of the [floating-point](#floating-point) and
[bit manipulation](#bit-manipulation) instructions with one source,
`rs1` of `MFCR`, `rd` of `MTCR`, `rd` of `TLBI` and its `rs1` in mode 2. A `TLBI` mode other than 0–2 in `imm14` is an illegal instruction
too. This keeps them free for future extensions.

`imm14` is sign-extended, except for `ANDI`, `ORI`, `XORI`, `SHLI`, `SHRI`,
`SARI` and `RORI`, where it is zero-extended. Shift and rotate amounts use
the low 5 bits.

## Opcodes

### System

| Opcode | Mnemonic        | Format | Operation                              |
|--------|-----------------|--------|----------------------------------------|
| `0x00` | `HLT`           | N      | halt the CPU (S)                       |
| `0x01` | `NOP`           | N      | do nothing                             |
| `0x02` | `WFI`           | N      | wait for interrupt (S)                 |
| `0x03` | `IRET`          | N      | `pc = EPC`, `IE = PIE`, `UM = PUM`, `SS = PSS`, `EXL = 0` (S) |
| `0x04` | `MFCR rd, cr`   | I      | `rd = cr[imm14]` (`rs1` is reserved) (S, except counters) |
| `0x05` | `MTCR cr, rs1`  | I      | `cr[imm14] = rs1` (`rd` is reserved) (S) |
| `0x06` | `TLBI rs1, mode`| I      | drop TLB entries, `mode` = `imm14`, see [TLB](#tlb) (`rd` is reserved) (S) |
| `0x07` | `SYSCALL`       | N      | enter the handler with `CAUSE` = 12    |
| `0x08` | `FENCE`         | N      | order memory operations                 |
| `0x09` | `BREAK`         | N      | enter the handler with `CAUSE` = 13    |

(S) — supervisor only, see [Privilege modes](#privilege-modes).

How `SYSCALL` passes its number and arguments is a software convention,
see [ABI.md](ABI.md#system-calls).

`MFCR`/`MTCR` with a control register number that doesn't exist, and
`MTCR` to a read-only one, is an illegal instruction.

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
| `0x1F` | `MULH rd, rs1, rs2` | high 32 bits, signed × signed  |
| `0x2A` | `MULHU rd, rs1, rs2` | high 32 bits, unsigned × unsigned |
| `0x2B` | `MULHSU rd, rs1, rs2` | high 32 bits, signed × unsigned |

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

### Bit manipulation

All are R-type except `RORI`, which is I-type like `SHLI`. The ones with
a single source have `rs2` reserved.

| Opcode | Mnemonic              | Operation                                        |
|--------|-----------------------|--------------------------------------------------|
| `0x90` | `CLZ rd, rs1`         | `rd` = zero bits above the highest 1 bit of `rs1`, 32 for 0 |
| `0x91` | `CTZ rd, rs1`         | `rd` = zero bits below the lowest 1 bit of `rs1`, 32 for 0 |
| `0x92` | `POPCNT rd, rs1`      | `rd` = number of 1 bits in `rs1`                 |
| `0x93` | `BSWAP rd, rs1`       | the bytes of `rs1` in reverse order              |
| `0x94` | `SEXT.B rd, rs1`      | `rs1` bits 7:0, sign-extended                    |
| `0x95` | `SEXT.H rd, rs1`      | `rs1` bits 15:0, sign-extended                   |
| `0x96` | `ROL rd, rs1, rs2`    | `rs1` rotated left by `rs2`                      |
| `0x97` | `ROR rd, rs1, rs2`    | `rs1` rotated right by `rs2`                     |
| `0x98` | `RORI rd, rs1, imm`   | `rs1` rotated right by `imm`                     |
| `0x99` | `MIN rd, rs1, rs2`    | the smaller of the two (signed)                  |
| `0x9A` | `MAX rd, rs1, rs2`    | the larger of the two (signed)                   |
| `0x9B` | `MINU rd, rs1, rs2`   | the smaller of the two (unsigned)                |
| `0x9C` | `MAXU rd, rs1, rs2`   | the larger of the two (unsigned)                 |

A rotate left by `n` is a rotate right by `32 - n`, so there is no `ROLI`.
Zero-extending a byte is `ANDI rd, rs1, 0xFF`; a half-word takes `SHLI`
and `SHRI` by 16.

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

### Atomic word operations

All atomic addresses are `rs1` (no offset) and must be word aligned.
`LL rd, (rs1)` (`0x4B`) reads a word and reserves its physical address
(`rs2` is reserved).
`SC rd, rs2, (rs1)` (`0x4C`) stores `rs2` only if that physical word remains
reserved, writing `0` to `rd` on success or `1` on failure. `SC` always
clears the reservation and checks alignment and write permission even on
failure. A failed `SC` does not set the PTE dirty bit.

`LL`/`SC` loops can implement swap, fetch-add and compare-and-swap.
CPU instructions and DMA ticks cannot interleave with a successful `SC`.
Atomic operations on device registers have device-specific side effects
and should be avoided.

Any CPU or DMA write overlapping the reserved physical word, a trap,
`MTCR PTBR`, `TLBI`, or a reset clears the reservation. `FENCE` orders
earlier memory operations before later ones; this single-core machine
already executes them in order.

### Modifying code

The CPU fetches ahead, so the instructions right after a store may
already have been fetched before the store writes memory. Code that
writes instructions (a program loader, a debugger setting `BREAK`) must
transfer control before executing them: a taken branch, `JAL`, `JALR`,
`IRET`, `MTCR STATUS`, `MTCR PTBR` or `TLBI` that comes after the store
makes every instruction executed after it come from the updated memory. The same
holds for code written by DMA once software has seen the device finish
(for example, by reading `DONE`) and then transfers control. Falling
through into modified code without such an instruction may execute
either the old or the new words. `FENCE` doesn't order instruction
fetches.

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

### Floating point

Floating-point values are IEEE 754 binary32 (`float`) held in the general
purpose registers; there is no separate register file. They are loaded,
stored, moved and passed like any other word. All floating-point
instructions are R-type and take one cycle in EX, like the integer ALU.

| Opcode | Mnemonic               | Operation                                   |
|--------|------------------------|---------------------------------------------|
| `0x70` | `FADD rd, rs1, rs2`    | `rd = rs1 + rs2`                            |
| `0x71` | `FSUB rd, rs1, rs2`    | `rd = rs1 - rs2`                            |
| `0x72` | `FMUL rd, rs1, rs2`    | `rd = rs1 × rs2`                            |
| `0x73` | `FDIV rd, rs1, rs2`    | `rd = rs1 / rs2`                            |
| `0x74` | `FSQRT rd, rs1`        | `rd = √rs1` (`rs2` is reserved)             |
| `0x75` | `FMIN rd, rs1, rs2`    | `rd = min(rs1, rs2)`                        |
| `0x76` | `FMAX rd, rs1, rs2`    | `rd = max(rs1, rs2)`                        |
| `0x77` | `FMADD rd, rs1, rs2`   | `rd = rd + rs1 × rs2`, rounded once         |
| `0x78` | `FMSUB rd, rs1, rs2`   | `rd = rd - rs1 × rs2`, rounded once         |
| `0x79` | `FSGNJ rd, rs1, rs2`   | `rs1` with the sign of `rs2`                |
| `0x7A` | `FSGNJN rd, rs1, rs2`  | `rs1` with the opposite sign of `rs2`       |
| `0x7B` | `FSGNJX rd, rs1, rs2`  | `rs1` with the sign of `rs1` xor the sign of `rs2` |
| `0x80` | `FEQ rd, rs1, rs2`     | `rd = rs1 == rs2`                           |
| `0x81` | `FLT rd, rs1, rs2`     | `rd = rs1 < rs2`                            |
| `0x82` | `FLE rd, rs1, rs2`     | `rd = rs1 <= rs2`                           |
| `0x83` | `FCLASS rd, rs1`       | `rd` = class of `rs1`, see below (`rs2` is reserved) |
| `0x84` | `FTOI rd, rs1`         | float → signed integer (`rs2` is reserved)  |
| `0x85` | `FTOU rd, rs1`         | float → unsigned integer (`rs2` is reserved) |
| `0x86` | `ITOF rd, rs1`         | signed integer → float (`rs2` is reserved)  |
| `0x87` | `UTOF rd, rs1`         | unsigned integer → float (`rs2` is reserved) |

`FMADD` and `FMSUB` read `rd` as their third source, like stores and
branches do.

Results are rounded in the rounding mode of
[`FCSR`](#floating-point-environment), to nearest with ties to even after
reset, except `FTOI`/`FTOU`, which always round toward zero like a C
cast. Subnormal numbers are supported. There are no floating-point traps:
an invalid operation gives NaN, an overflow gives ±infinity or the
largest finite number (depending on the rounding mode), division by zero
gives ±infinity (or NaN for `0 / 0`), and each of them sets its flag in
`FCSR`.

- **NaN.** Every instruction that computes a NaN (`FADD` to `FMSUB`)
  returns the canonical NaN `0x7FC00000`; the payload and sign of NaN
  operands are not propagated. `FSGNJ`, `FSGNJN` and `FSGNJX` only move
  the sign bit and never change the other bits, even of a NaN.
- **Comparisons** write `1` or `0`. A NaN operand makes all of them `0`,
  so `FEQ rd, rs, rs` is `0` only for a NaN. `-0` and `+0` are equal.
- **`FMIN`/`FMAX`** return the other operand when one of them is NaN, and
  the canonical NaN when both are. `-0` counts as less than `+0`.
- **`FTOI`/`FTOU`** saturate: a value too large for the result gives the
  largest integer (`0x7FFFFFFF` or `0xFFFFFFFF`), a value too small the
  smallest (`0x80000000` or `0`); NaN gives the largest.
- **`FCLASS`** sets exactly one bit of `rd`:

  | Bit | Class of `rs1`     | Bit | Class of `rs1`      |
  |-----|--------------------|-----|---------------------|
  | 0   | −infinity          | 5   | positive subnormal  |
  | 1   | negative normal    | 6   | positive normal     |
  | 2   | negative subnormal | 7   | +infinity           |
  | 3   | −0                 | 8   | signaling NaN       |
  | 4   | +0                 | 9   | quiet NaN           |

The assembler has pseudo-instructions for the common sign operations:
`fmv rd, rs` (`FSGNJ rd, rs, rs`), `fneg rd, rs` (`FSGNJN rd, rs, rs`),
`fabs rd, rs` (`FSGNJX rd, rs, rs`), and `fgt`/`fge`, which are
`FLT`/`FLE` with the operands swapped. `fli rd, 1.5` loads the bits of a
float constant, and `.float` emits them as data.

### Floating-point environment

`FCSR` (control register 17) holds the IEEE 754 exception flags and the
rounding mode. Unlike the other control registers, user mode can read
and write it with `MFCR` and `MTCR`, so `<fenv.h>` needs no system call.

| Bits | Field    | Description                                        |
|------|----------|----------------------------------------------------|
| 0    | `NX`     | inexact: the result was rounded                    |
| 1    | `UF`     | underflow: an inexact result below the smallest normal number |
| 2    | `OF`     | overflow: the rounded result is too large          |
| 3    | `DZ`     | division by zero: `FDIV` of a finite nonzero number by zero |
| 4    | `NV`     | invalid operation                                  |
| 7:5  | `FRM`    | rounding mode, see below                           |

| `FRM` | Rounding                                            |
|-------|-----------------------------------------------------|
| `0`   | `RNE`: to nearest, ties to even (the value after reset) |
| `1`   | `RTZ`: toward zero                                  |
| `2`   | `RDN`: toward −infinity                             |
| `3`   | `RUP`: toward +infinity                             |
| `4`   | `RMM`: to nearest, ties away from zero              |

Other bits read as zero. `FRM` values 5–7 are reserved: a write of one
leaves `FRM` as it was and still writes the flags.

The flags are sticky: an instruction only sets them, software clears
them by writing `FCSR`. They are set when the instruction retires, so an
instruction squashed in the pipeline sets none, and `MFCR` of `FCSR`
sees the flags of every instruction before it. `MTCR FCSR` refetches the
instructions after it, like `MTCR STATUS`, so they round in the new mode.

What sets which flag:

- **`NV`:** a signaling NaN operand of any arithmetic instruction, of
  `FMIN`/`FMAX` and of `FEQ`; any NaN operand of `FLT`/`FLE`; ∞ − ∞
  (also within `FMADD`/`FMSUB`), 0 × ∞ (even with a NaN addend), 0 / 0,
  ∞ / ∞, the square root of a number below zero (but −0); `FTOI`/`FTOU`
  of NaN, ±infinity or a value out of range, including `FTOU` of −1 and
  below. Such results are the canonical NaN, or the saturated integer.
- **`DZ`:** `FDIV` of a finite nonzero number by ±0.
- **`OF`:** the result rounded with an unbounded exponent is too large;
  `NX` is set with it.
- **`UF`:** the result is nonzero, below the smallest normal number
  (2<sup>−126</sup>) before rounding, and inexact. Tininess is detected
  before rounding.
- **`NX`:** the result differs from the exact one: rounded, overflowed,
  or a fraction cut off by `FTOI`/`FTOU`.

`FSGNJ`, `FSGNJN`, `FSGNJX` and `FCLASS` set no flags. An exact
result that cancels to zero is +0 except in `RDN`, where it is −0.

## Interrupts

### Control registers

| Number | Name      | Reset | Description                                  |
|--------|-----------|-------|----------------------------------------------|
| `0`    | `STATUS`  | `0x10` | bit 0 = `IE` (interrupts enabled), bit 1 = `PIE` (previous `IE`), bit 2 = `UM` (user mode), bit 3 = `PUM` (previous `UM`), bit 4 = `EXL` (in the handler, see [Exceptions](#exceptions)), bit 5 = `SS` (single step), bit 6 = `PSS` (previous `SS`), see [Debugging](#debugging); other bits read as zero |
| `1`    | `EPC`     | `0`   | address `IRET` returns to                    |
| `2`    | `IVEC`    | `0`   | interrupt handler address                    |
| `3`    | `SCRATCH` | `0`   | free for software, e.g. to save a register in the handler |
| `4`    | `CAUSE`   | `0`   | why the handler was entered, see [Exceptions](#exceptions) |
| `5`    | `BADADDR` | `0`   | faulting address or instruction word          |
| `6`    | `PTBR`    | `0`   | page table base, see [Memory management](#memory-management) |
| `7`    | `CYCLE`   | `0`   | clock cycles since reset, low 32 bits (read-only) |
| `8`    | `CYCLEH`  | `0`   | clock cycles since reset, high 32 bits (read-only) |
| `9`    | `INSTRET` | `0`   | instructions retired since reset, low 32 bits (read-only) |
| `10`   | `INSTRETH`| `0`   | instructions retired since reset, high 32 bits (read-only) |
| `11`   | `CPUID`   | see below | the ISA version and its extensions (read-only) |
| `12`   | `TADDR0`  | `0`   | trigger 0: address, see [Triggers](#triggers) |
| `13`   | `TCTRL0`  | `0`   | trigger 0: what it matches                    |
| `14`   | `TADDR1`  | `0`   | trigger 1: address                            |
| `15`   | `TCTRL1`  | `0`   | trigger 1: what it matches                    |
| `16`   | `HARTID`  | `0`   | the number of this core, always 0 (read-only), see [Cores](#cores) |
| `17`   | `FCSR`    | `0`   | FP exception flags and rounding mode, also in user mode, see [Floating-point environment](#floating-point-environment) |

### Taking an interrupt

The CPU has one level-triggered IRQ input driven by the PIC (see
[SPECIFICATION.md](SPECIFICATION.md)). When it is asserted, `IE` is set and
`EXL` is clear, the CPU finishes the current instruction and then:

1. `EPC` = address of the next instruction that has not executed yet,
2. `PIE` = `IE`, `IE` = 0,
3. `PUM` = `UM`, `UM` = 0 (supervisor mode),
4. `PSS` = `SS`, `SS` = 0,
5. `EXL` = 1,
6. `CAUSE` = 0,
7. `pc` = `IVEC`.

Interrupts and [exceptions](#exceptions) share the handler; it tells them
apart by `CAUSE`.

The handler finds the source by reading the PIC `CLAIM` register and must
clear the condition in the device before `IRET`, otherwise the line stays
asserted and the interrupt is taken again right after `IRET`.

A handler that allows nested interrupts saves `EPC` and `STATUS` first,
then clears `EXL` and sets `IE`; before restoring `EPC` it clears `IE`
again (and sets `EXL`, or restores the saved `STATUS`) and executes `IRET`.

### WFI

`WFI` stops fetching until the IRQ line is asserted. If `IE` is set and
`EXL` clear, the interrupt is taken with `EPC` pointing after the `WFI`;
otherwise execution simply continues with the next instruction.

### Control register access

`MFCR`, `MTCR` and `IRET` wait until all older instructions have finished,
so they always see the effect of preceding `MTCR`s. `MTCR` takes effect when
it completes: an interrupt can arrive right after `MTCR STATUS` sets `IE`
(or clears `EXL`), but never after an `MTCR` that clears `IE` (or sets
`EXL`).

A mode change takes effect for the next instruction: `IRET` jumps to `EPC`
only when it completes, and `MTCR STATUS` (and `MTCR FCSR`) refetches the
instructions after it. Writing `UM` with `MTCR` switches to user mode directly, continuing
after the `MTCR`.

### Counters

`CYCLE`/`CYCLEH` and `INSTRET`/`INSTRETH` are two 64-bit counters split
into halves. They are read-only and, unlike the other control registers
but `FCSR`, can be read with `MFCR` in user mode too.

- `CYCLE` counts clock cycles, including the ones spent in `WFI`. It
  stops while the CPU is halted.
- `INSTRET` counts completed instructions. Instructions that fault
  (including `SYSCALL`) and instructions squashed in the pipeline are not
  counted; interrupts are not instructions.

`MFCR` waits for the older instructions like for any control register, so
`MFCR rd, instret` returns the number of instructions completed before it.
A 64-bit value takes three reads; retry if the high half changed:

```
again:  mfcr r2, cycleh
        mfcr r1, cycle
        mfcr r3, cycleh
        bne r2, r3, again
```

### CPUID

`CPUID` tells software what the CPU implements, so an OS or a runtime
can check instead of assuming. It is read-only and, like the other
control registers, supervisor only; an OS passes on what user code needs.

| Bits  | Field     | Value                                      |
|-------|-----------|--------------------------------------------|
| 31:24 | `VERSION` | the ISA version, `1` for this document     |
| 23:0  | extensions, one bit each | set if implemented          |

| Bit | Extension                                                  |
|-----|------------------------------------------------------------|
| 0   | MMU: `PTBR`, paging and `TLBI`, see [Memory management](#memory-management) |
| 1   | [floating point](#floating-point), binary32 in the GPRs    |
| 2   | `LL` and `SC`                                              |
| 3   | `MULH`, `MULHU` and `MULHSU`                               |
| 4   | `TLBI` modes 1 and 2, see [TLB](#tlb)                      |
| 5   | [debugging](#debugging): `STATUS.SS` and the triggers      |
| 6   | [bit manipulation](#bit-manipulation): `CLZ` to `MAXU`     |
| 7   | [`FCSR`](#floating-point-environment): FP flags and rounding modes |

Other bits read as zero. This CPU implements all of them: `CPUID` reads
`0x010000FF`.

### Cores

The machine has one core, and the instruction set is described for one.
`HARTID` (control register 16) is the number of the core that reads it,
always 0 here; it is read-only and supervisor only, like `CPUID`. A
kernel that keeps its per-CPU data (the current thread, its stack, run
queues) in a table indexed by `HARTID` rather than in plain globals is
ready for more cores without a rewrite.

Should a machine with several cores come, the rest is meant to work like
this: every core resets with its own `HARTID`, core 0 runs the firmware
and the others wait for an interprocessor interrupt; `LL`/`SC` reserve a
physical word against writes from every core and DMA; `FENCE` orders
this core's memory operations as the others see them; a TLB caches
translations for its own core only, so changing a mapping that other
cores may have cached takes an interrupt to each of them to run `TLBI`
(a TLB shootdown).

## Exceptions

A fault is raised when the faulting instruction would complete; the
instructions before it have completed, the ones after it have no effect.

The CPU enters the handler in supervisor mode like for an interrupt,
except:

1. `EPC` = address of the faulting instruction,
2. `PIE` = `IE`, `IE` = 0,
3. `PUM` = `UM`, `UM` = 0,
4. `PSS` = `SS`, `SS` = 0,
5. `EXL` = 1,
6. `CAUSE` = fault code, `BADADDR` = see the table,
7. `pc` = `IVEC`.

`IRET` retries the faulting instruction; to skip it (e.g. after emulating
it, or to return from `SYSCALL`) the handler adds 4 to `EPC` first.

A fault is handled in both modes, whatever `IE` is: `IE` only masks
interrupts, so the supervisor can take a page fault (e.g. while copying
`SYSCALL` arguments from user memory) with interrupts disabled.

`EXL` marks the part of the handler that can't be interrupted: the
handler entry sets it, `IRET` clears it. While it is set, interrupts are
not taken, and a fault can't be handled — `EPC`, `CAUSE`, `BADADDR` and
`PIE`/`PUM` would be lost — so it halts the CPU with `pc` left pointing at
the faulting instruction (a double fault). `EXL` is set after reset, so
faults halt until software has set `IVEC` and cleared `EXL` (any `MTCR
STATUS` that doesn't set bit 4, or an `IRET`).

A handler that may fault itself (a `SYSCALL` handler that reads user
memory, a page fault handler that touches pageable memory) first saves
`EPC`, `CAUSE`, `BADADDR` and `STATUS`, then clears `EXL`; the nested fault
enters the handler again. Before `IRET` it sets `EXL` again (or restores
the saved `STATUS`) and then restores `EPC`, so that a fault can't come
between the two.

| `CAUSE` | Fault                   | `BADADDR`                         |
|---------|-------------------------|-----------------------------------|
| `0`     | interrupt (not a fault) | unchanged                         |
| `1`     | illegal instruction: unknown opcode or control register, a reserved bit set, `MTCR` to a read-only one | instruction word |
| `2`     | misaligned fetch        | `pc`                              |
| `3`     | misaligned load         | virtual address                   |
| `4`     | misaligned store        | virtual address                   |
| `5`     | fetch bus error, including fetches from the I/O region | `pc` |
| `6`     | load bus error          | virtual address                   |
| `7`     | store bus error, including writes to ROM | virtual address  |
| `8`     | fetch page fault        | `pc`                              |
| `9`     | load page fault         | virtual address                   |
| `10`    | store page fault        | virtual address                   |
| `11`    | privileged instruction in user mode | instruction word      |
| `12`    | `SYSCALL`               | `0`                               |
| `13`    | `BREAK`                 | `0`                               |
| `14`    | single step (not a fault: `EPC` is the next instruction, see [Debugging](#debugging)) | address of the instruction that ran |
| `15`    | a trigger matched       | `pc` for a fetch, the virtual address for a load or store |

`BREAK` is an unprivileged software breakpoint. Its exception points `EPC`
at the `BREAK` instruction; the handler can advance `EPC` by 4 to skip it.

Bus errors are accesses to unmapped physical memory (see
[SPECIFICATION.md](SPECIFICATION.md#memory-map)). Code can only run from
RAM and ROM: a fetch from the I/O region (`0xFD000000`–`0xFDFFFFFF`) is a
fetch bus error and never reaches the device, even when the page is
mapped with `X`. Since the CPU fetches ahead of branches, this keeps a
fetch that is later squashed from reading a device register.

## Debugging

A debugger running in the supervisor (or a monitor in the firmware) can
stop a program after every instruction and at any address, also in ROM,
where it can't write `BREAK`. Both stop it with a trap to the handler, like
the other exceptions, and neither happens while `EXL` is set: the handler
itself is never stepped or stopped, and can't halt the CPU that way.

### Single step

While `STATUS.SS` is set and `EXL` clear, each instruction that completes
is followed by a single step trap (`CAUSE` = 14): `EPC` is the address of
the next instruction, the one that would run now, and `BADADDR` the
address of the one that ran. An instruction that faults doesn't complete:
its fault is taken instead. The trap saves `SS` in `PSS` and clears it, so
the handler isn't stepped; `IRET` restores it.

What counts is `SS` as the instruction starts: after `MTCR STATUS` that
sets `SS` the trap comes after the next instruction, after one that clears
it the trap still follows it. `HLT` halts without a trap; `WFI` takes the
trap instead of waiting.

To step a program, the debugger sets `PSS` in the `STATUS` it returns with
and executes `IRET`: the instruction at `EPC` runs, then the handler is
entered again with `EPC` pointing past it.

### Triggers

Two triggers watch virtual addresses: trigger 0 is `TADDR0` and `TCTRL0`,
trigger 1 is `TADDR1` and `TCTRL1`.

| Bits  | `TCTRL` field | Meaning                                         |
|-------|---------------|-------------------------------------------------|
| 0     | `X`           | match instruction fetches                       |
| 1     | `R`           | match loads (`LB`–`LW`, `LL`)                   |
| 2     | `W`           | match stores (`SB`–`SW`, `SC`)                  |
| 12:8  | `SIZE`        | the range is 2<sup>`SIZE`</sup> bytes, aligned, that holds `TADDR` |

Other bits read as zero. Like `MTCR STATUS`, `MTCR` to a trigger register
takes effect for the next instruction. A trigger matches an access that
touches any byte of its range; with none of `X`, `R`, `W` set it is off (the value after
reset). A match is a fault (`CAUSE` = 15), raised before the instruction
has any effect: `EPC` is the instruction, `BADADDR` the address that
matched — `pc` for a fetch, the virtual address for a load or store. A
load or store is checked after its alignment and before the MMU, so a
misaligned access faults as such and a match comes before a page fault; a
fetch is checked after it is made, so a fetch fault comes first.

`IRET` back to the instruction matches again. To go on, the handler turns
the trigger off, sets `PSS` and returns; on the single step trap it turns
the trigger on again and clears `PSS`.

## Memory management

The MMU translates every virtual address (fetches, loads and stores) to a
physical one with a two-level page table. Pages are 4KB; a directory entry
can also map a 4MB superpage.

Translation is off after reset: virtual = physical. It is controlled by
`PTBR`:

```
PTBR  31                        12 11       4 3  1   0
     | directory physical address |   ASID   | rsvd | EN |
```

- `EN` — translation on,
- `ASID` — 8-bit address-space identifier,
- the directory is one 4KB page of 1024 entries, aligned to 4KB.

Reserved bits read as zero. Translation affects the handler too: `IVEC`,
`EPC` and `BADADDR` hold virtual addresses.

### Page tables

```
Virtual address  31        22 21        12 11            0
                | dir index  | table index |    offset    |

Entry            31                     12 11  8  7  6  5  4 3 2 1 0
                |  physical page address  | rsvd | G | D | A | U X W R V |
```

1. The directory entry is read from `PTBR.base + dir index * 4`.
2. If it has `V` = 0, it is a page fault.
3. If any of `R`, `W`, `X` is set, it maps a 4MB superpage: the physical
   address is `entry[31:22]` + `vaddr[21:0]`. Bits 21–12 of the entry
   must be zero, otherwise it is a page fault.
4. Otherwise it points to a page table at `entry[31:12]`; the page table
   entry is read from `table + table index * 4`.
5. If it has `V` = 0, or none of `R`, `W`, `X` set, it is a page fault.
   The physical address is `entry[31:12]` + `vaddr[11:0]`.

A fetch needs `X`, a load needs `R`, a store needs `W`, otherwise it is a
page fault. In user mode the page also needs `U`; supervisor mode skips
the `U` check but still needs `R`, `W` or `X`. `U` is only checked in the
entry that maps the page (a superpage directory entry or a page table
entry). On a permitted
translation, the MMU sets `A` in the leaf PTE and sets `D` for a write.
It writes the PTE back to physical memory, so leaf page tables must be in
RAM unless their `A`/`D` bits were preset. A writeback failure is a page
fault. The MMU may set `A` on a speculative instruction fetch. `G` marks
a mapping shared across ASIDs; on a non-leaf directory entry it applies to
all pages in that table. An entry that can't be read
(unmapped physical address, or an address in the I/O region — the walk
never reads a device register) is a page fault.

Devices are only reachable through a mapping of their physical pages, so
software usually maps the I/O region and the ROM too, e.g. with
superpages.

### TLB

The CPU caches translations in a TLB. After changing an entry, software
must drop the stale translation with `TLBI`, whose `imm14` selects what
it drops:

| `imm14` | Assembly        | Drops                                          |
|---------|-----------------|------------------------------------------------|
| `0`     | `TLBI rs1`      | the translation of the 4KB page containing `rs1` for the current ASID, including a matching global translation |
| `1`     | `TLBI.ASID rs1` | every non-global translation of the ASID in `rs1` bits 7:0, current or not |
| `2`     | `TLBI.ALL`      | every translation, global ones too (`rs1` is reserved) |

A superpage may be cached as 4KB translations, so `TLBI rs1` drops only
the part of it around `rs1`; `TLBI.ALL` drops a changed global superpage
in one go. `TLBI.ASID` lets an OS reuse an ASID for a new address space
without switching to it first.

Writing `PTBR` with the current ASID refreshes that ASID's non-global
translations, like `TLBI.ASID`. Switching to another ASID retains cached
entries from the previous context. `G` entries remain cached until
`TLBI` or reset.

Software must invalidate entries after changing page tables, including
global mappings and ASIDs reused for different address spaces.

Both take effect for the next instruction: `MTCR PTBR` and `TLBI` refetch
the instructions after them. Entries with `V` = 0 are never cached, so
making an entry valid needs no `TLBI`. A valid entry is cached by the
walk before its permissions are checked, so adding a permission (`W` to a
page after a store page fault, `U` or `X`) also needs a `TLBI`: without it
the retried access faults again. The number of TLB entries is not part of
the architecture.
