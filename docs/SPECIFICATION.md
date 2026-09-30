# WRM.081632 Specification

## Memory map

| Range                     | Device                                  |
|---------------------------|-----------------------------------------|
| `0x00000000`–…            | RAM, installed slots mapped back to back |
| `0xFE000000`–`0xFFFFFFFF` | ROM (32MB, read-only)                   |

Addresses between the end of RAM and `0xFE000000` are unmapped.
RAM slots are laid out in slot order; empty slots take no address space.

## Reset

On reset all registers are zero and `pc = 0xFE000000`, so execution starts
at the first byte of the firmware image.

## Pipeline

The CPU uses the classic five-stage RISC pipeline, one stage per clock cycle:

| Stage | Work                                                        |
|-------|-------------------------------------------------------------|
| IF    | fetch the word at `pc`, `pc += 4`                           |
| ID    | decode, read registers, detect load-use hazards             |
| EX    | ALU, effective address, branch/jump resolution              |
| MEM   | loads and stores                                            |
| WB    | write `rd`, retire, raise faults, `HLT`                     |

The pipeline is invisible to software: there are no delay slots, and
results are always seen by the next instruction.

- **Forwarding:** EX takes operands from EX/MEM and MEM/WB. The register
  file is written before it is read in the same cycle.
- **Load-use:** an instruction that needs the result of the load right
  before it stalls for 1 cycle.
- **Branches:** predicted not taken and resolved in EX. A taken branch or
  any jump squashes the two following instructions (2-cycle penalty).
- **Faults** are precise: they are raised when the faulting instruction
  reaches WB, after all older instructions have completed and before any
  younger one has written memory or registers.

Timing: an instruction takes 5 cycles to go through the pipeline; the
throughput is up to one instruction per cycle.

See [INSTRUCTIONS.md](INSTRUCTIONS.md) for the instruction set.
