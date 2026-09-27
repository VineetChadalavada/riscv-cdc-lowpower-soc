# rtl/core: the CPU

These three files are the CPU, copied unchanged from TinyTrust, the
author's earlier RISC-V project:

| File | What it is |
|---|---|
| `core_p5.v` | RV32I, 5-stage pipeline (IF/ID/EX/MEM/WB), full forwarding, one-cycle load-use stall, machine-mode traps and interrupts, 4-region PMP |
| `regfile.v` | 32 x 32-bit register file, write-through so a read in the same cycle as a write sees the new value |
| `pmp.v` | Physical memory protection |

This SoC treats the core as IP: it connects to its ports and does not
change it. That is how a real SoC integrates a CPU, and it keeps this
project about what surrounds the core.

How the core was verified, in TinyTrust (not repeated here):

- lockstep co-simulation against an instruction set simulator written from
  the RISC-V specification, over 1.2 million random instructions with no
  mismatches;
- riscv-formal, the standard formal check suite for RISC-V cores;
- 17 directed pipeline tests (forwarding, stalls, flushes, traps), each also
  run against a deliberately broken core to show it catches the fault.

Comments inside these files refer to TinyTrust's design documents
(`docs/RETARGET.md` and others) and bug log entries (`BUG-005`), which are
not part of this repository.

`dv/common/rv_asm_pkg.sv`, the small assembler the tests use to write
programs, is copied from the same place.
