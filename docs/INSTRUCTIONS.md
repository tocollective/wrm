# WRM.081632 Instructions

All instructions are 32 bits wide, little-endian and must be 4-byte aligned.
The opcode is always the lowest byte.

## Registers

- `r0`–`r31` — 32-bit general purpose registers, `r0` always reads as zero.
- `pc` — program counter, reset value `0xFE000000` (start of ROM).
- `cr0`–`cr10` — control registers, see [Control registers](#control-registers).

## Privilege modes

The CPU runs either in **supervisor** or in **user** mode, selected by
`STATUS.UM`. It starts in supervisor mode after reset.

User mode can't:

- execute `HLT`, `WFI`, `IRET`, `MFCR`, `MTCR` and `TLBI` — they raise a
  privileged instruction fault; `MFCR` of the
  [counters](#counters) is the exception,
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
`imm14` [31:18], `imm19` [31:13]. Reserved bits should be zero.

`imm14` is sign-extended, except for `ANDI`, `ORI`, `XORI`, `SHLI`, `SHRI`
and `SARI`, where it is zero-extended. Shift amounts use the low 5 bits.

## Opcodes

### System

| Opcode | Mnemonic        | Format | Operation                              |
|--------|-----------------|--------|----------------------------------------|
| `0x00` | `HLT`           | N      | halt the CPU (S)                       |
| `0x01` | `NOP`           | N      | do nothing                             |
| `0x02` | `WFI`           | N      | wait for interrupt (S)                 |
| `0x03` | `IRET`          | N      | `pc = EPC`, `IE = PIE`, `UM = PUM`, `EXL = 0` (S) |
| `0x04` | `MFCR rd, cr`   | I      | `rd = cr[imm14]` (S, except counters)  |
| `0x05` | `MTCR cr, rs1`  | I      | `cr[imm14] = rs1` (`rd` is reserved) (S) |
| `0x06` | `TLBI rs1`      | I      | drop the TLB entry of the page at `rs1` (`rd`, `imm14` are reserved) (S) |
| `0x07` | `SYSCALL`       | N      | enter the handler with `CAUSE` = 12    |

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
| `0`    | `STATUS`  | `0x10` | bit 0 = `IE` (interrupts enabled), bit 1 = `PIE` (previous `IE`), bit 2 = `UM` (user mode), bit 3 = `PUM` (previous `UM`), bit 4 = `EXL` (in the handler, see [Exceptions](#exceptions)); other bits read as zero |
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

### Taking an interrupt

The CPU has one level-triggered IRQ input driven by the PIC (see
[SPECIFICATION.md](SPECIFICATION.md)). When it is asserted, `IE` is set and
`EXL` is clear, the CPU finishes the current instruction and then:

1. `EPC` = address of the next instruction that has not executed yet,
2. `PIE` = `IE`, `IE` = 0,
3. `PUM` = `UM`, `UM` = 0 (supervisor mode),
4. `EXL` = 1,
5. `CAUSE` = 0,
6. `pc` = `IVEC`.

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
only when it completes, and `MTCR STATUS` refetches the instructions after
it. Writing `UM` with `MTCR` switches to user mode directly, continuing
after the `MTCR`.

### Counters

`CYCLE`/`CYCLEH` and `INSTRET`/`INSTRETH` are two 64-bit counters split
into halves. They are read-only and, unlike the other control registers,
can be read with `MFCR` in user mode too.

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

## Exceptions

A fault is raised when the faulting instruction would complete; the
instructions before it have completed, the ones after it have no effect.

The CPU enters the handler in supervisor mode like for an interrupt,
except:

1. `EPC` = address of the faulting instruction,
2. `PIE` = `IE`, `IE` = 0,
3. `PUM` = `UM`, `UM` = 0,
4. `EXL` = 1,
5. `CAUSE` = fault code, `BADADDR` = see the table,
6. `pc` = `IVEC`.

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
| `1`     | illegal instruction: unknown opcode or control register, `MTCR` to a read-only one | instruction word |
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

Bus errors are accesses to unmapped physical memory (see
[SPECIFICATION.md](SPECIFICATION.md#memory-map)). Code can only run from
RAM and ROM: a fetch from the I/O region (`0xFD000000`–`0xFDFFFFFF`) is a
fetch bus error and never reaches the device, even when the page is
mapped with `X`. Since the CPU fetches ahead of branches, this keeps a
fetch that is later squashed from reading a device register.

## Memory management

The MMU translates every virtual address (fetches, loads and stores) to a
physical one with a two-level page table. Pages are 4KB; a directory entry
can also map a 4MB superpage.

Translation is off after reset: virtual = physical. It is controlled by
`PTBR`:

```
PTBR  31                        12 11          1   0
     | directory physical address |  reserved   | EN |
```

- `EN` — translation on,
- the directory is one 4KB page of 1024 entries, aligned to 4KB.

Reserved bits read as zero. Translation affects the handler too: `IVEC`,
`EPC` and `BADADDR` hold virtual addresses.

### Page tables

```
Virtual address  31        22 21        12 11            0
                | dir index  | table index |    offset    |

Entry            31                     12 11  5  4   3   2   1   0
                |  physical page address  | rsvd | U | X | W | R | V |
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
page fault. In user mode the page also needs `U`; supervisor mode can
access every page. `U` is only checked in the entry that maps the page
(a superpage directory entry or a page table entry). Entries are read from physical memory and never written by the
CPU. Page tables must be in RAM or ROM. An entry that can't be read
(unmapped physical address, or an address in the I/O region — the walk
never reads a device register) is a page fault.

Devices are only reachable through a mapping of their physical pages, so
software usually maps the I/O region and the ROM too, e.g. with
superpages.

### TLB

The CPU caches translations in a TLB. After changing an entry, software
must drop the stale translation:

- `TLBI rs1` drops the translation of the 4KB page containing `rs1`;
- writing `PTBR` (even with the same value) drops all of them — needed
  after changing a directory entry, since a superpage is cached one 4KB
  page at a time.

Both take effect for the next instruction: `MTCR PTBR` and `TLBI` refetch
the instructions after them. Entries with `V` = 0 are never cached, so
making an entry valid needs no `TLBI`. The number of TLB entries is not
part of the architecture.
