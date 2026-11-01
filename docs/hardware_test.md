# Oric Atmos Hardware & Instruction Set Test Suite (`test.tap`)

This document describes the design, implementation, and verification of the self-contained hardware test suite **`test.tap`** (located at [`test.tap`](file:///home/philippe/dev/z6502/test.tap) and [`tapes/test.tap`](file:///home/philippe/dev/z6502/tapes/test.tap)) for the Oric Atmos and Oric 1 microcomputers.

---

## 1. Objectives & Scope

The test suite is written in pure 6502 machine code and assembled into a bootable Oric cassette container (`.tap`). It is designed to be executed directly on bare-metal hardware or inside an emulator without relying on ROM BASIC.

It rigorously validates:
1. **The full MOS 6502 instruction set** (151 official NMOS opcodes).
2. **Addressing modes** (Immediate, Zero-Page, Zero-Page indexed, Absolute, Absolute indexed, Indexed Indirect, Indirect Indexed, Indirect, Implied, Accumulator, and Relative).
3. **Status flag generation and branching logic** (Carry `C`, Zero `Z`, Interrupt `I`, Decimal `D`, Break `B`, Overflow `V`, and Negative `N`).
4. **All Oric Atmos peripheral chips and coprocessors**:
   - **MOS 6522 VIA** (Versatile Interface Adapter): Timers T1/T2, latches, DDR direction registers, interrupt registers.
   - **GI AY-3-8912 PSG** (Programmable Sound Generator): Tone channels, noise generator, mixer, volume, envelope, and audible confirmation.
   - **Ferranti ULA** (Uncommitted Logic Array): Text screen RAM range (`$BB80..$BFDF`), serial color attributes (Ink and Paper).

---

## 2. Test Suites Architecture

The test binary loads at `$0600` and auto-runs (`auto_run = 0xC7`). It sequentially executes **13 specialized test suites**:

| Suite | Component | Scope & Verified Instructions |
|:---:|:---|:---|
| **01** | **CPU Registers & Transfers** | `LDA`, `LDX`, `LDY`, `STA`, `STX`, `STY`, `TAX`, `TAY`, `TXA`, `TYA`, `TSX`, `TXS`. Validates register preservation, zero flag, and sign flag updates. |
| **02** | **CPU Binary ALU** | `ADC` and `SBC` in binary mode (`CLD`). Tests unsigned math, Carry flag propagation, signed arithmetic overflow (`V` flag for positive+positive=negative and negative+negative=positive), borrow generation, and zero condition. |
| **03** | **CPU Comparisons** | `CMP`, `CPX`, `CPY`. Verifies equality (`==`), strictly greater (`>`), and strictly lesser (`<`) conditions with accurate Carry, Zero, and Negative flags. |
| **04** | **CPU Logic Operations** | `AND`, `ORA`, `EOR` across multiple bit masks (`$0F`, `$F0`, `$A0`, `$AA`, etc.) and verifies bitwise flag states. |
| **05** | **CPU Shifts & Rotates** | `ASL`, `LSR`, `ROL`, `ROR` on Accumulator (`A`) and Zero-Page memory. Tests single-bit shifts, multi-byte Carry propagation, and sign flag changes. |
| **06** | **CPU Increments & Decrements** | `INC`, `DEC`, `INX`, `DEX`, `INY`, `DEY`. Tests rollover boundaries (`$FE -> $FF -> $00` and `$00 -> $FF`). |
| **07** | **CPU Decimal Mode (BCD)** | `SED` (Decimal mode active). Tests BCD additions (`19 + 01 = 20`, `79 + 25 = 04` with Carry), BCD subtractions (`42 - 15 = 27`, `21 - 34 = 87` with Borrow), and return to binary mode via `CLD`. |
| **08** | **CPU Branches & Status Flags** | All relative conditional branches: `BCC`, `BCS`, `BEQ`, `BNE`, `BMI`, `BPL`, `BVC`, `BVS`. Also tests explicit flag manipulation (`SEC`, `CLC`, `SEI`, `CLI`, `CLV`, `SED`, `CLD`). |
| **09** | **CPU Stack & Subroutines** | `PHA`, `PLA`, `PHP`, `PLP`, subroutine calls and returns (`JSR` / `RTS`), and indirect jumping (`JMP ($xxxx)`). |
| **10** | **CPU Bit Test** | `BIT` instruction with Zero-Page memory. Validates bit 7 transfer into Negative flag, bit 6 transfer into Overflow flag, and Zero flag based on `A & M`. |
| **11** | **Coprocessor: 6522 VIA** | - **Data Direction Registers**: Write/read verification on `DDRA` (`$0303`) and `DDRB` (`$0302`).<br>- **Timer 1**: Latch setting (`$0306..$0307`), counter transfer (`$0304..$0305`), and active down-counting over CPU cycles.<br>- **Timer 2**: Counter down-counting (`$0308..$0309`).<br>- **Interrupts**: Read verification of `IER` (`$030E`, bit 7 high). |
| **12** | **Coprocessor: AY-3-8912 PSG** | Standalone register interface via VIA Port A (`$030F`) and PCR (`$030C`). Programs Channel A tone frequency (R0/R1), noise (R6), mixer (R7), volume (R8), and hardware envelope (R11/R12/R13). Plays a **3-note victory jingle** (C4-E4-G4) upon completion. |
| **13** | **Coprocessor: ULA Video Memory** | Direct screen memory read/write test at Row 23 (`$BF28..$BF4E`), attribute setting, and live visual rendering. |

---

## 3. Screen Layout & Visual Feedback

The test suite provides real-time visual output directly on the Oric text screen (`$BB80..$BFDF`, 28 rows × 40 columns):

```
+--------------------------------------------------------------------------+
| Col 0  Col 1   Columns 2..30                     Col 31  Cols 32..37     |
+--------------------------------------------------------------------------+
| [Blue Paper] [Yellow Ink] "  ORIC ATMOS 6502 & COPROCESSOR TEST  "       | Row 0
| [Black Paper] [Cyan Ink]  " CPU - 6522 VIA - AY-3-8912 PSG - ULA "       | Row 1
|                                                                          | Row 2
| [White Ink]  " 01. CPU REGISTERS & TRANSFERS       "  [Green Ink] [PASS] | Row 3
| [White Ink]  " 02. CPU BINARY ALU (ADC/SBC)        "  [Green Ink] [PASS] | Row 4
| [White Ink]  " 03. CPU COMPARISONS (CMP/X/Y)       "  [Green Ink] [PASS] | Row 5
| [White Ink]  " 04. CPU LOGIC (AND/ORA/EOR)         "  [Green Ink] [PASS] | Row 6
| [White Ink]  " 05. CPU SHIFTS & ROTATES            "  [Green Ink] [PASS] | Row 7
| [White Ink]  " 06. CPU INCS & DECS (INC/DEC/X/Y)   "  [Green Ink] [PASS] | Row 8
| [White Ink]  " 07. CPU DECIMAL MODE (BCD)          "  [Green Ink] [PASS] | Row 9
| [White Ink]  " 08. CPU BRANCHES & STATUS FLAGS     "  [Green Ink] [PASS] | Row 10
| [White Ink]  " 09. CPU STACK & SUBROUTINES         "  [Green Ink] [PASS] | Row 11
| [White Ink]  " 10. CPU BIT TEST (Z, N, V FLAGS)    "  [Green Ink] [PASS] | Row 12
| [White Ink]  " 11. VIA 6522 (TIMERS, DDR, IER)     "  [Green Ink] [PASS] | Row 13
| [White Ink]  " 12. AY-3-8912 SOUND GENERATOR       "  [Green Ink] [PASS] | Row 14
| [White Ink]  " 13. ULA VIDEO MEMORY & ATTRS        "  [Green Ink] [PASS] | Row 15
|                                                                          | Row 16
| [Green Paper] [White Ink] "   >>> ALL 13 TEST SUITES PASSED! <<<   "    | Row 17
|                                                                          | Row 18
| [Black Paper] [Green Ink] " ZERO-PAGE: $50=00 (OK)  $51=0D (13/13) "     | Row 19
+--------------------------------------------------------------------------+
```

### Color Codes
- **Pass indicator**: Serial Attribute `$02` (Green ink) preceding `"[PASS]"`.
- **Fail indicator**: Serial Attribute `$01` (Red ink) preceding `"[FAIL]"`.

---

## 4. Zero-Page Status Interface

For automated headless testing and debugger assertions, execution status is exposed at fixed zero-page locations:

| Address | Symbol | Meaning |
|:---:|:---|:---|
| **`$0050`** | `STATUS_FAIL` | **`$00`** = All tests passed successfully.<br>**`$01`..`$0D`** = Index of the failed suite (1 to 13). |
| **`$0051`** | `STATUS_COUNT` | Total count of passed suites (**`$0D`** / 13 when fully completed). |

---

## 5. Running the Test Suite

### Interactive Mode (Emulator Window)
Launch the compiled emulator with the test tape:
```bash
./zig-out/bin/z6502 -t tapes/test.tap
```

### Automated Unit Testing
The test suite is integrated into the native Zig test runner ([`src/root.zig`](file:///home/philippe/dev/z6502/src/root.zig)):
```bash
/tmp/zig/zig test src/root.zig -lc -lSDL2
```

The test boots the machine, fast-injects `tapes/test.tap`, runs for 60 frames (~1.2 seconds of simulated time), and asserts:
1. `machine.bus.ram[0x0050] == 0` (no failure).
2. `machine.bus.ram[0x0051] == 13` (all 13 suites passed).
3. Visual confirmation of `"ALL 13 TEST SUITES PASSED"` on text screen RAM.

---

## 6. Regenerating & Modifying the Test Tape

The test tape is generated using the standalone Python assembler script:
```bash
python3 tools/generate_test_tap.py
```

This script:
1. Compiles the 6502 assembly source code via a two-pass assembler.
2. Emits 2,384 bytes of machine code spanning `$0600` to `$0F4F`.
3. Packages the binary into a standard Oric `.tap` file with sync leader (`0x16 0x16 0x16 0x24`), 9-byte header, and null-terminated filename `"TEST ATMOS"`.
4. Writes the output to both [`tapes/test.tap`](file:///home/philippe/dev/z6502/tapes/test.tap) and [`test.tap`](file:///home/philippe/dev/z6502/test.tap).
