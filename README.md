# PDP-11 emulator

An emulator of the PDP-11 minicomputer written in Zig. The project aims to
faithfully reproduce the base instruction set of the real machine, including
instruction encodings, addressing modes and condition-code behaviour, so that
binaries produced by real PDP-11 assemblers can run unmodified.

Requires Zig 0.17.1.

## Building and running

```
zig build-exe main.zig -femit-bin=pdp11
./pdp11 program.bin
./pdp11 program.asm
```

A `.bin` file is loaded as a raw binary image into memory starting at
address 0, PC is set to 0 and the program runs until a HALT (word 0) or an
illegal instruction. A `.asm` file is assembled first (see below), the
resulting image is then executed the same way.

## The assembler

The bundled two-pass assembler understands a small subset of MACRO-11 syntax.
Example (`example.asm` in the repository root):

```
        mov #msg, r0        ; R0 = address of the string (PC-relative)
        mov #15, r1
loop:   movb (r0)+, @#0o177566
        sob r1, loop
        halt
msg:    .ascii "Hello, PDP-11!"
        .byte 10
```

Supported syntax:

- Registers `r0`–`r7`, `sp` and `pc`; mnemonics are case-insensitive, and a
  trailing `b` selects the byte variant (`movb`, `clrb`, ...).
- Operands in MACRO-11 notation: `rn`, `@rn`, `(rn)+`, `@(rn)+`, `-(rn)`,
  `@-(rn)`, `x(rn)`, `@x(rn)`, `#imm`, `@#imm`, and a bare label or expression,
  which is assembled as PC-relative `x(pc)`.
- All implemented instructions: the MOV/CMP/BIT/BIC/BIS/ADD/SUB group,
  the CLR/TST/shift group, JMP, JSR, RTS, SOB, all fifteen branches, HALT.
- Directives `.byte`, `.word` and `.ascii`.
- Numbers are decimal by default; `0o177566` is octal; `'c` is a character
  literal.

Assembler diagnostics are printed to stderr with a line number.

## Running tests

```
zig test tests.zig
zig test assembler.zig
zig test ioFiler.zig
zig test tty.zig
```

`tests.zig` holds instruction-level tests written with small assembly helpers;
`assembler.zig` and the other files contain unit tests for their own modules.

## What is implemented

- The full base instruction set in both word and byte variants:
  MOV, CMP, BIT, BIC, BIS, ADD, SUB, CLR, COM, INC, DEC, NEG, ADC, SBC, TST,
  ROR, ROL, ASR, ASL, SXT, JMP, JSR, RTS, SOB, HALT.
- All fifteen conditional branches with real condition semantics.
- All eight addressing modes, including PC-relative and immediate addressing,
  with correct side-effect ordering.
- Processor status word with C, V, Z and N flags following DEC's rules.
- Unaligned word access and illegal instructions are reported and stop
  execution instead of corrupting state.

## Known limitations

- MARK, MFPI, MTPI, EMT, TRAP and the floating-point set are treated as
  illegal instructions.
- Console I/O is emulated as a stub: a guest prints characters by writing
  them to the DL11 buffer at 0o177566, which is mirrored to the host
  console. There is no real device emulation or keyboard input yet.
- No interrupt or trap handling; the CPU runs with priority 7 semantics
  collapsed to "never interrupted".

## Goals

- Traps and interrupts: vector dispatch through the interrupt stack, priority
  levels, the trace bit, stack overflow (yellow) and stack error (orange)
  traps.
- EIS instructions: MUL, DIV, ASH, ASHC; the FIS and FPP-11 floating point
  sets.
- MMU emulation with separate instruction/data (I/D) spaces and 22-bit
  addressing as on the 11/70.
- Real device emulation over a bus model: DL11 console with keyboard input,
  KW11 line clock, RK05 disk, and bootstrap ROM loading.
- A loader for a real object format (a.out) so that programs assembled by
  MACRO-11 can be run directly.
- A disassembler mode for debugging guest programs.
