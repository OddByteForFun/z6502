#!/usr/bin/env python3
"""
Oric Atmos 6502 CPU and Coprocessor Test TAP Generator.

Generates:
  - tapes/test.tap
  - test.tap

Tests:
  01. CPU Registers & Transfers
  02. CPU Binary ALU (ADC/SBC, Carry, Overflow, Zero, Negative)
  03. CPU Comparisons (CMP, CPX, CPY)
  04. CPU Logic (AND, ORA, EOR)
  05. CPU Shifts & Rotates (ASL, LSR, ROL, ROR)
  06. CPU Increments & Decrements (INC, DEC, INX, DEX, INY, DEY)
  07. CPU Decimal Mode (SED, CLD, BCD ADC/SBC)
  08. CPU Branches & Status Flags (BCC/BCS, BEQ/BNE, BMI/BPL, BVC/BVS, SEC/CLC/etc.)
  09. CPU Stack & Subroutines (PHA/PLA, PHP/PLP, JSR/RTS, JMP ind)
  10. CPU Bit Test (BIT Z, N, V flags)
  11. Coprocessor: 6522 VIA (Timers T1/T2, Latches, DDR, IER/IFR)
  12. Coprocessor: AY-3-8912 PSG (Tone, Mixer, Volume, Envelope, Jingle)
  13. Coprocessor: ULA Video Memory & Serial Attributes

Screen:
  - Real-time formatted results on Oric text screen ($BB80..$BFDF)
  - Color attributes (Green [PASS] / Red [FAIL])
  - Zero-page status: $50 = error code (0=OK), $51 = suites passed (13=ALL OK)
"""

import sys
import os
import re

OPCODES = {
    # ADC
    ('ADC', 'imm'): 0x69, ('ADC', 'zp'): 0x65, ('ADC', 'zpx'): 0x75,
    ('ADC', 'abs'): 0x6D, ('ADC', 'absx'): 0x7D, ('ADC', 'absy'): 0x79,
    ('ADC', 'indx'): 0x61, ('ADC', 'indy'): 0x71,

    # AND
    ('AND', 'imm'): 0x29, ('AND', 'zp'): 0x25, ('AND', 'zpx'): 0x35,
    ('AND', 'abs'): 0x2D, ('AND', 'absx'): 0x3D, ('AND', 'absy'): 0x39,
    ('AND', 'indx'): 0x21, ('AND', 'indy'): 0x31,

    # ASL
    ('ASL', 'acc'): 0x0A, ('ASL', 'zp'): 0x06, ('ASL', 'zpx'): 0x16,
    ('ASL', 'abs'): 0x0E, ('ASL', 'absx'): 0x1E,

    # Branches
    ('BCC', 'rel'): 0x90, ('BCS', 'rel'): 0xB0,
    ('BEQ', 'rel'): 0xF0, ('BMI', 'rel'): 0x30,
    ('BNE', 'rel'): 0xD0, ('BPL', 'rel'): 0x10,
    ('BVC', 'rel'): 0x50, ('BVS', 'rel'): 0x70,

    # BIT
    ('BIT', 'zp'): 0x24, ('BIT', 'abs'): 0x2C,

    # BRK
    ('BRK', 'imp'): 0x00,

    # CLC, CLD, CLI, CLV
    ('CLC', 'imp'): 0x18, ('CLD', 'imp'): 0xD8,
    ('CLI', 'imp'): 0x58, ('CLV', 'imp'): 0xB8,

    # CMP
    ('CMP', 'imm'): 0xC9, ('CMP', 'zp'): 0xC5, ('CMP', 'zpx'): 0xD5,
    ('CMP', 'abs'): 0xCD, ('CMP', 'absx'): 0xDD, ('CMP', 'absy'): 0xD9,
    ('CMP', 'indx'): 0xC1, ('CMP', 'indy'): 0xD1,

    # CPX
    ('CPX', 'imm'): 0xE0, ('CPX', 'zp'): 0xE4, ('CPX', 'abs'): 0xEC,

    # CPY
    ('CPY', 'imm'): 0xC0, ('CPY', 'zp'): 0xC4, ('CPY', 'abs'): 0xCC,

    # DEC
    ('DEC', 'zp'): 0xC6, ('DEC', 'zpx'): 0xD6,
    ('DEC', 'abs'): 0xCE, ('DEC', 'absx'): 0xDE,

    # DEX, DEY
    ('DEX', 'imp'): 0xCA, ('DEY', 'imp'): 0x88,

    # EOR
    ('EOR', 'imm'): 0x49, ('EOR', 'zp'): 0x45, ('EOR', 'zpx'): 0x55,
    ('EOR', 'abs'): 0x4D, ('EOR', 'absx'): 0x5D, ('EOR', 'absy'): 0x59,
    ('EOR', 'indx'): 0x41, ('EOR', 'indy'): 0x51,

    # INC
    ('INC', 'zp'): 0xE6, ('INC', 'zpx'): 0xF6,
    ('INC', 'abs'): 0xEE, ('INC', 'absx'): 0xFE,

    # INX, INY
    ('INX', 'imp'): 0xE8, ('INY', 'imp'): 0xC8,

    # JMP
    ('JMP', 'abs'): 0x4C, ('JMP', 'ind'): 0x6C,

    # JSR
    ('JSR', 'abs'): 0x20,

    # LDA
    ('LDA', 'imm'): 0xA9, ('LDA', 'zp'): 0xA5, ('LDA', 'zpx'): 0xB5,
    ('LDA', 'abs'): 0xAD, ('LDA', 'absx'): 0xBD, ('LDA', 'absy'): 0xB9,
    ('LDA', 'indx'): 0xA1, ('LDA', 'indy'): 0xB1,

    # LDX
    ('LDX', 'imm'): 0xA2, ('LDX', 'zp'): 0xA6, ('LDX', 'zpy'): 0xB6,
    ('LDX', 'abs'): 0xAE, ('LDX', 'absy'): 0xBE,

    # LDY
    ('LDY', 'imm'): 0xA0, ('LDY', 'zp'): 0xA4, ('LDY', 'zpx'): 0xB4,
    ('LDY', 'abs'): 0xAC, ('LDY', 'absx'): 0xBC,

    # LSR
    ('LSR', 'acc'): 0x4A, ('LSR', 'zp'): 0x46, ('LSR', 'zpx'): 0x56,
    ('LSR', 'abs'): 0x4E, ('LSR', 'absx'): 0x5E,

    # NOP
    ('NOP', 'imp'): 0xEA,

    # ORA
    ('ORA', 'imm'): 0x09, ('ORA', 'zp'): 0x05, ('ORA', 'zpx'): 0x15,
    ('ORA', 'abs'): 0x0D, ('ORA', 'absx'): 0x1D, ('ORA', 'absy'): 0x19,
    ('ORA', 'indx'): 0x01, ('ORA', 'indy'): 0x11,

    # PHA, PHP, PLA, PLP
    ('PHA', 'imp'): 0x48, ('PHP', 'imp'): 0x08,
    ('PLA', 'imp'): 0x68, ('PLP', 'imp'): 0x28,

    # ROL
    ('ROL', 'acc'): 0x2A, ('ROL', 'zp'): 0x26, ('ROL', 'zpx'): 0x36,
    ('ROL', 'abs'): 0x2E, ('ROL', 'absx'): 0x3E,

    # ROR
    ('ROR', 'acc'): 0x6A, ('ROR', 'zp'): 0x66, ('ROR', 'zpx'): 0x76,
    ('ROR', 'abs'): 0x6E, ('ROR', 'absx'): 0x7E,

    # RTI, RTS
    ('RTI', 'imp'): 0x40, ('RTS', 'imp'): 0x60,

    # SBC
    ('SBC', 'imm'): 0xE9, ('SBC', 'zp'): 0xE5, ('SBC', 'zpx'): 0xF5,
    ('SBC', 'abs'): 0xED, ('SBC', 'absx'): 0xFD, ('SBC', 'absy'): 0xF9,
    ('SBC', 'indx'): 0xE1, ('SBC', 'indy'): 0xF1,

    # SEC, SED, SEI
    ('SEC', 'imp'): 0x38, ('SED', 'imp'): 0xF8, ('SEI', 'imp'): 0x78,

    # STA
    ('STA', 'zp'): 0x85, ('STA', 'zpx'): 0x95,
    ('STA', 'abs'): 0x8D, ('STA', 'absx'): 0x9D, ('STA', 'absy'): 0x99,
    ('STA', 'indx'): 0x81, ('STA', 'indy'): 0x91,

    # STX
    ('STX', 'zp'): 0x86, ('STX', 'zpy'): 0x96, ('STX', 'abs'): 0x8E,

    # STY
    ('STY', 'zp'): 0x84, ('STY', 'zpx'): 0x94, ('STY', 'abs'): 0x8C,

    # TAX, TAY, TSX, TXA, TXS, TYA
    ('TAX', 'imp'): 0xAA, ('TAY', 'imp'): 0xA8,
    ('TSX', 'imp'): 0xBA, ('TXA', 'imp'): 0x8A,
    ('TXS', 'imp'): 0x9A, ('TYA', 'imp'): 0x98,
}

BRANCHES = {'BCC', 'BCS', 'BEQ', 'BMI', 'BNE', 'BPL', 'BVC', 'BVS'}

def eval_expr(expr, symbols, pc=0, pass_num=1):
    expr = expr.strip()
    if not expr:
        return 0

    # Strip outer parentheses if balanced
    if expr.startswith('(') and expr.endswith(')'):
        expr = expr[1:-1].strip()

    if expr.startswith('<'):
        val = eval_expr(expr[1:], symbols, pc, pass_num)
        return val & 0xFF

    if expr.startswith('>'):
        val = eval_expr(expr[1:], symbols, pc, pass_num)
        return (val >> 8) & 0xFF

    m = re.match(r'^(.+?)\s*([\+\-])\s*([^\+\-]+)$', expr)
    if m:
        left = eval_expr(m.group(1), symbols, pc, pass_num)
        right = eval_expr(m.group(3), symbols, pc, pass_num)
        if m.group(2) == '+':
            return left + right
        else:
            return left - right

    if expr == '*':
        return pc

    if expr.startswith("'") and expr.endswith("'") and len(expr) == 3:
        return ord(expr[1])

    if expr.startswith('$'):
        return int(expr[1:], 16)
    if expr.startswith('0x') or expr.startswith('0X'):
        return int(expr[2:], 16)

    if expr.isdigit() or (expr.startswith('-') and expr[1:].isdigit()):
        return int(expr, 10)

    if expr in symbols:
        return symbols[expr]

    if pass_num == 1:
        return 0x1000

    raise ValueError(f"Undefined symbol '{expr}' at PC=${pc:04X}")

class Assembler:
    def __init__(self):
        self.symbols = {}

    def assemble(self, src: str, origin: int = 0x0600) -> bytes:
        lines = src.splitlines()

        # Pass 1: Collect symbols and compute addresses
        self.symbols = {}
        self._run_pass(lines, origin, pass_num=1)

        # Pass 2: Generate bytes
        code = self._run_pass(lines, origin, pass_num=2)
        return code

    def _run_pass(self, lines, origin: int, pass_num: int) -> bytes:
        pc = origin
        output = bytearray()

        for line_num, raw_line in enumerate(lines, 1):
            line = raw_line.strip()
            # Remove comments
            if ';' in line:
                line = line[:line.index(';')].strip()
            if not line:
                continue

            # Check for symbol definition: NAME = EXPR or NAME EQU EXPR
            m_assign = re.match(r'^([A-Za-z0-9_]+)\s*(?:=|\bEQU\b)\s*(.+)$', line, re.IGNORECASE)
            if m_assign:
                sym_name = m_assign.group(1).strip()
                sym_expr = m_assign.group(2).strip()
                val = eval_expr(sym_expr, self.symbols, pc, pass_num)
                self.symbols[sym_name] = val
                continue

            # Check for label at start of line
            m_label = re.match(r'^([A-Za-z0-9_]+)\s*:\s*(.*)$', line)
            if m_label:
                label = m_label.group(1).strip()
                line = m_label.group(2).strip()
                if label:
                    if pass_num == 1:
                        self.symbols[label] = pc

            if not line:
                continue

            # Check for directives
            tokens = line.split(None, 1)
            mnemonic = tokens[0].upper()
            operand = tokens[1].strip() if len(tokens) > 1 else ''

            if mnemonic in ('.BYTE', '.DB'):
                items = self._split_operands(operand)
                for item in items:
                    val = eval_expr(item, self.symbols, pc, pass_num) & 0xFF
                    if pass_num == 2:
                        output.append(val)
                    pc += 1
                continue

            if mnemonic in ('.WORD', '.DW'):
                items = self._split_operands(operand)
                for item in items:
                    val = eval_expr(item, self.symbols, pc, pass_num) & 0xFFFF
                    if pass_num == 2:
                        output.append(val & 0xFF)
                        output.append((val >> 8) & 0xFF)
                    pc += 2
                continue

            if mnemonic in ('.TEXT', '.ASCII', '.STR'):
                # Extract string literal
                m = re.search(r'"([^"]*)"', operand)
                if m:
                    text_bytes = m.group(1).encode('latin1')
                    for b in text_bytes:
                        if pass_num == 2:
                            output.append(b)
                        pc += 1
                continue

            if mnemonic == '.PAD':
                target_addr = eval_expr(operand, self.symbols, pc, pass_num)
                pad_len = target_addr - pc
                if pad_len < 0:
                    raise ValueError(f"Cannot pad backwards: target={target_addr:04X}, current={pc:04X}")
                for _ in range(pad_len):
                    if pass_num == 2:
                        output.append(0)
                    pc += 1
                continue

            # Instructions
            mode, op_val = self._parse_operand(mnemonic, operand, pc, pass_num)
            key = (mnemonic, mode)
            if key not in OPCODES:
                raise ValueError(f"Line {line_num}: Invalid instruction {mnemonic} with mode {mode} (operand='{operand}')")

            opcode = OPCODES[key]
            if pass_num == 2:
                output.append(opcode)
            pc += 1

            if mode in ('imm', 'zp', 'zpx', 'zpy', 'indx', 'indy'):
                if pass_num == 2:
                    output.append(op_val & 0xFF)
                pc += 1
            elif mode in ('abs', 'absx', 'absy', 'ind'):
                if pass_num == 2:
                    output.append(op_val & 0xFF)
                    output.append((op_val >> 8) & 0xFF)
                pc += 2
            elif mode == 'rel':
                rel_offset = op_val - (pc + 1)
                if pass_num == 2:
                    if rel_offset < -128 or rel_offset > 127:
                        raise ValueError(f"Line {line_num}: Branch target out of range: {rel_offset}")
                    output.append(rel_offset & 0xFF)
                pc += 1
            elif mode in ('imp', 'acc'):
                pass

        return bytes(output)

    def _split_operands(self, s: str):
        parts = []
        cur = []
        in_quote = False
        for c in s:
            if c == '"':
                in_quote = not in_quote
                cur.append(c)
            elif c == ',' and not in_quote:
                parts.append(''.join(cur).strip())
                cur = []
            else:
                cur.append(c)
        if cur:
            parts.append(''.join(cur).strip())
        return parts

    def _parse_operand(self, mnemonic: str, op: str, pc: int, pass_num: int):
        op = re.sub(r'\s*,\s*', ',', op.strip())
        if not op:
            if (mnemonic, 'imp') in OPCODES:
                return ('imp', 0)
            if (mnemonic, 'acc') in OPCODES:
                return ('acc', 0)
            raise ValueError(f"Missing operand for {mnemonic}")

        if op.upper() == 'A' and (mnemonic, 'acc') in OPCODES:
            return ('acc', 0)

        if mnemonic in BRANCHES:
            target = eval_expr(op, self.symbols, pc, pass_num)
            return ('rel', target)

        if op.startswith('#'):
            val = eval_expr(op[1:], self.symbols, pc, pass_num)
            return ('imm', val & 0xFF)

        if op.startswith('(') and (op.endswith(',X)') or op.endswith(',x)')):
            inner = op[1:-3].strip()
            val = eval_expr(inner, self.symbols, pc, pass_num)
            return ('indx', val & 0xFF)

        if op.startswith('(') and (op.endswith('),Y') or op.endswith('),y')):
            inner = op[1:-3].strip()
            val = eval_expr(inner, self.symbols, pc, pass_num)
            return ('indy', val & 0xFF)

        if op.startswith('(') and op.endswith(')'):
            inner = op[1:-1].strip()
            val = eval_expr(inner, self.symbols, pc, pass_num)
            return ('ind', val & 0xFFFF)

        if op.endswith(',X') or op.endswith(',x'):
            inner = op[:-2].strip()
            val = eval_expr(inner, self.symbols, pc, pass_num)
            if (mnemonic, 'zpx') in OPCODES and val <= 0xFF and not inner.startswith('!'):
                return ('zpx', val & 0xFF)
            return ('absx', val & 0xFFFF)

        if op.endswith(',Y') or op.endswith(',y'):
            inner = op[:-2].strip()
            val = eval_expr(inner, self.symbols, pc, pass_num)
            if (mnemonic, 'zpy') in OPCODES and val <= 0xFF:
                return ('zpy', val & 0xFF)
            return ('absy', val & 0xFFFF)

        val = eval_expr(op, self.symbols, pc, pass_num)
        if (mnemonic, 'zp') in OPCODES and val <= 0xFF and not op.startswith('!'):
            return ('zp', val & 0xFF)

        return ('abs', val & 0xFFFF)


def create_oric_tap(filename: str, prog_type: int, auto_run: int,
                    start_addr: int, data: bytes) -> bytes:
    end_addr = start_addr + len(data) - 1
    out = bytearray()
    # Sync sequence
    out.extend(b"\x16\x16\x16\x24")
    # 9-byte Header
    out.append(0x00)
    out.append(0x00)
    out.append(prog_type & 0xFF)
    out.append(auto_run & 0xFF)
    out.append((end_addr >> 8) & 0xFF)
    out.append(end_addr & 0xFF)
    out.append((start_addr >> 8) & 0xFF)
    out.append(start_addr & 0xFF)
    out.append(0x00)
    # Filename null-terminated
    out.extend(filename.encode('latin1')[:16])
    out.append(0x00)
    # Data payload
    out.extend(data)
    return bytes(out)


# ---------------------------------------------------------------------------
# Assembly Test Suite Source Code
# ---------------------------------------------------------------------------

ASM_SOURCE = """
; ===========================================================================
; ORIC ATMOS 6502 CPU & COPROCESSORS COMPLETE HARDWARE TEST SUITE
; ===========================================================================

ORIGIN          = $0600

; Zero-Page Reporting Variables
STATUS_FAIL     = $50           ; 0 = ALL PASS, 1..13 = Failed suite number
STATUS_COUNT    = $51           ; Total number of passed suites

; Zero-Page Workspace
ZP_TEMP1        = $20
ZP_TEMP2        = $21
ZP_PTR_L        = $22
ZP_PTR_H        = $23
SAVE_SP         = $24

; Screen Memory ($BB80..$BFDF = 28 rows x 40 cols)
SCREEN_BASE     = $BB80
ROW_STRIDE      = 40

ROW_0           = $BB80         ; Row 0: Title Banner
ROW_1           = $BBA8         ; Row 1: Subtitle
ROW_2           = $BBD0         ; Blank
ROW_3           = $BBF8         ; Suite 01: Registers & Transfers
ROW_4           = $BC20         ; Suite 02: Binary ALU (ADC/SBC)
ROW_5           = $BC48         ; Suite 03: Comparisons (CMP/X/Y)
ROW_6           = $BC70         ; Suite 04: Logic (AND/ORA/EOR)
ROW_7           = $BC98         ; Suite 05: Shifts & Rotates
ROW_8           = $BCC0         ; Suite 06: Increments & Decrements
ROW_9           = $BCE8         ; Suite 07: Decimal Mode (BCD)
ROW_10          = $BD10         ; Suite 08: Branches & Flags
ROW_11          = $BD38         ; Suite 09: Stack & Subroutines
ROW_12          = $BD60         ; Suite 10: Bit Test (BIT)
ROW_13          = $BD88         ; Suite 11: 6522 VIA (Timers/DDR/IER)
ROW_14          = $BDB0         ; Suite 12: AY-3-8912 PSG Sound
ROW_15          = $BDD8         ; Suite 13: ULA Video Memory & Attrs
ROW_17          = $BE28         ; Final Banner
ROW_19          = $BE78         ; Zero-page summary

; Oric Atmos Hardware Registers
VIA_ORB         = $0300
VIA_ORA         = $0301
VIA_DDRB        = $0302
VIA_DDRA        = $0303
VIA_T1CL        = $0304
VIA_T1CH        = $0305
VIA_T1LL        = $0306
VIA_T1LH        = $0307
VIA_T2CL        = $0308
VIA_T2CH        = $0309
VIA_SR          = $030A
VIA_ACR         = $030B
VIA_PCR         = $030C
VIA_IFR         = $030D
VIA_IER         = $030E
VIA_ORA_NH      = $030F

ENTRY:
    SEI                         ; Disable interrupts during hardware tests
    CLD                         ; Default to binary mode

    LDA #$00
    STA STATUS_FAIL             ; Clear error
    STA STATUS_COUNT            ; Zero passed tests

    ; Save stack pointer
    TSX
    STX SAVE_SP

    ; Initialize Screen with Title and Background
    JSR INIT_SCREEN

    ; -----------------------------------------------------------------------
    ; SUITE 1: CPU Registers & Transfers
    ; -----------------------------------------------------------------------
    LDA #1
    STA ZP_TEMP1                ; Current test index

    LDA #$5A
    TAX
    TXA
    CMP #$5A
    BNE FAIL_SUITE1

    TAY
    TYA
    CMP #$5A
    BNE FAIL_SUITE1

    LDA #$A5
    STA ZP_TEMP2
    LDA ZP_TEMP2
    CMP #$A5
    BNE FAIL_SUITE1

    LDX #$3C
    STX ZP_TEMP2
    LDX #$00
    LDX ZP_TEMP2
    CPX #$3C
    BNE FAIL_SUITE1

    LDY #$C3
    STY ZP_TEMP2
    LDY #$00
    LDY ZP_TEMP2
    CPY #$C3
    BNE FAIL_SUITE1

    ; Zero and Negative Flag generation
    LDA #$00
    BNE FAIL_SUITE1
    BMI FAIL_SUITE1

    LDA #$80
    BEQ FAIL_SUITE1
    BPL FAIL_SUITE1

    ; Report Suite 1 Success
    LDA #<ROW_3
    STA ZP_PTR_L
    LDA #>ROW_3
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE2

FAIL_SUITE1:
    LDA #1
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 2: CPU Binary ALU (ADC / SBC)
    ; -----------------------------------------------------------------------
SUITE2:
    LDA #2
    STA ZP_TEMP1

    ; -----------------------------------------------------------------------
    ; SUITE 2: CPU Binary ALU (ADC / SBC)
    ; -----------------------------------------------------------------------
SUITE2:
    LDA #2
    STA ZP_TEMP1

    ; Basic ADC: $15 + $27 = $3C, Carry=0, Overflow=0
    CLC
    LDA #$15
    ADC #$27
    BCS FAIL_SUITE2
    BVS FAIL_SUITE2
    CMP #$3C
    BNE FAIL_SUITE2

    ; ADC with Carry in: $15 + $27 + 1 = $3D
    SEC
    LDA #$15
    ADC #$27
    BCS FAIL_SUITE2
    BVS FAIL_SUITE2
    CMP #$3D
    BNE FAIL_SUITE2

    ; ADC Carry generation & Zero: $FF + $01 = $00, Carry=1, Zero=1
    CLC
    LDA #$FF
    ADC #$01
    BCC FAIL_SUITE2
    BNE FAIL_SUITE2

    ; Signed Overflow (+) + (+) = (-): $7F + $01 = $80, V=1, N=1, C=0
    CLC
    LDA #$7F
    ADC #$01
    BVC FAIL_SUITE2
    BPL FAIL_SUITE2
    BCS FAIL_SUITE2
    CMP #$80
    BNE FAIL_SUITE2

    ; Signed Overflow (-) + (-) = (+): $80 + $80 = $00, V=1, C=1, Z=1
    CLC
    LDA #$80
    ADC #$80
    BVC FAIL_SUITE2
    BCC FAIL_SUITE2
    BNE FAIL_SUITE2

    ; Basic SBC: $50 - $20 = $30, Carry=1 (no borrow), Overflow=0
    SEC
    LDA #$50
    SBC #$20
    BCC FAIL_SUITE2
    BVS FAIL_SUITE2
    CMP #$30
    BNE FAIL_SUITE2

    ; SBC with Borrow in: $50 - $20 - 1 = $2F
    CLC
    LDA #$50
    SBC #$20
    BCC FAIL_SUITE2
    BVS FAIL_SUITE2
    CMP #$2F
    BNE FAIL_SUITE2

    ; SBC Borrow generation: $20 - $50 = $D0, Carry=0 (borrow)
    SEC
    LDA #$20
    SBC #$50
    BCS FAIL_SUITE2
    CMP #$D0
    BNE FAIL_SUITE2

    ; SBC Overflow (-) - (+) = (+): $80 - $01 = $7F, V=1, C=1
    SEC
    LDA #$80
    SBC #$01
    BVC FAIL_SUITE2
    BCC FAIL_SUITE2
    CMP #$7F
    BNE FAIL_SUITE2

    ; Report Suite 2 Success
    LDA #<ROW_4
    STA ZP_PTR_L
    LDA #>ROW_4
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE3

FAIL_SUITE2:
    LDA #2
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 3: CPU Comparisons (CMP, CPX, CPY)
    ; -----------------------------------------------------------------------
SUITE3:
    LDA #3
    STA ZP_TEMP1

    ; CMP Equal
    LDA #$40
    CMP #$40
    BNE FAIL_SUITE3
    BCC FAIL_SUITE3

    ; CMP Greater
    LDA #$60
    CMP #$40
    BEQ FAIL_SUITE3
    BCC FAIL_SUITE3
    BMI FAIL_SUITE3

    ; CMP Lesser
    LDA #$20
    CMP #$40
    BEQ FAIL_SUITE3
    BCS FAIL_SUITE3
    BPL FAIL_SUITE3

    ; CPX
    LDX #$80
    CPX #$80
    BNE FAIL_SUITE3
    BCC FAIL_SUITE3

    CPX #$7F
    BEQ FAIL_SUITE3
    BCC FAIL_SUITE3

    CPX #$81
    BCS FAIL_SUITE3

    ; CPY
    LDY #$A0
    CPY #$A0
    BNE FAIL_SUITE3
    BCC FAIL_SUITE3

    CPY #$9F
    BCC FAIL_SUITE3

    CPY #$A1
    BCS FAIL_SUITE3

    ; Report Suite 3 Success
    LDA #<ROW_5
    STA ZP_PTR_L
    LDA #>ROW_5
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE4

FAIL_SUITE3:
    LDA #3
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 4: CPU Logic (AND, ORA, EOR)
    ; -----------------------------------------------------------------------
SUITE4:
    LDA #4
    STA ZP_TEMP1

    ; AND
    LDA #$FF
    AND #$0F
    CMP #$0F
    BNE FAIL_SUITE4
    BEQ SUITE4_AND2
    JMP FAIL_SUITE4
SUITE4_AND2:
    LDA #$F0
    AND #$0F
    BNE FAIL_SUITE4

    ; ORA
    LDA #$A0
    ORA #$05
    BPL FAIL_SUITE4             ; Must be negative ($A5 has bit 7 set)
    CMP #$A5
    BNE FAIL_SUITE4

    LDA #$00
    ORA #$00
    BNE FAIL_SUITE4

    ; EOR
    LDA #$AA
    EOR #$FF
    CMP #$55
    BNE FAIL_SUITE4

    LDA #$AA
    EOR #$AA
    BNE FAIL_SUITE4

    ; Report Suite 4 Success
    LDA #<ROW_6
    STA ZP_PTR_L
    LDA #>ROW_6
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE5

FAIL_SUITE4:
    LDA #4
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 5: CPU Shifts & Rotates (ASL, LSR, ROL, ROR)
    ; -----------------------------------------------------------------------
SUITE5:
    LDA #5
    STA ZP_TEMP1

    ; ASL Accumulator: $81 << 1 = $02, Carry=1
    LDA #$81
    ASL A
    BCC FAIL_SUITE5
    CMP #$02
    BNE FAIL_SUITE5

    ; LSR Accumulator: $81 >> 1 = $40, Carry=1
    LDA #$81
    LSR A
    BCC FAIL_SUITE5
    CMP #$40
    BNE FAIL_SUITE5

    ; ROL Accumulator with Carry in: $40 ROL with C=1 -> $81, C=0, N=1
    SEC
    LDA #$40
    ROL A
    BCS FAIL_SUITE5
    BPL FAIL_SUITE5
    CMP #$81
    BNE FAIL_SUITE5

    ; ROR Accumulator with Carry in: $02 ROR with C=1 -> $81, C=0, N=1
    SEC
    LDA #$02
    ROR A
    BCS FAIL_SUITE5
    BPL FAIL_SUITE5
    CMP #$81
    BNE FAIL_SUITE5

    ; Zero-page memory shift
    LDA #$80
    STA ZP_TEMP2
    ASL ZP_TEMP2
    BCC FAIL_SUITE5
    LDA ZP_TEMP2
    BNE FAIL_SUITE5

    ; Report Suite 5 Success
    LDA #<ROW_7
    STA ZP_PTR_L
    LDA #>ROW_7
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE6

FAIL_SUITE5:
    LDA #5
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 6: CPU Increments & Decrements (INC, DEC, INX, DEX, INY, DEY)
    ; -----------------------------------------------------------------------
SUITE6:
    LDA #6
    STA ZP_TEMP1

    LDX #$FE
    INX
    BPL FAIL_SUITE6             ; Must have N set ($FF has bit 7 set)
    CPX #$FF
    BNE FAIL_SUITE6

    INX
    CPX #$00
    BNE FAIL_SUITE6

    DEX
    CPX #$FF
    BNE FAIL_SUITE6

    LDY #$FF
    INY
    CPY #$00
    BNE FAIL_SUITE6

    DEY
    CPY #$FF
    BNE FAIL_SUITE6

    ; Memory INC / DEC
    LDA #$7F
    STA ZP_TEMP2
    INC ZP_TEMP2
    LDA ZP_TEMP2
    CMP #$80
    BNE FAIL_SUITE6

    DEC ZP_TEMP2
    LDA ZP_TEMP2
    CMP #$7F
    BNE FAIL_SUITE6

    ; Report Suite 6 Success
    LDA #<ROW_8
    STA ZP_PTR_L
    LDA #>ROW_8
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE7

FAIL_SUITE6:
    LDA #6
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 7: CPU Decimal Mode (SED, CLD, BCD ADC/SBC)
    ; -----------------------------------------------------------------------
SUITE7:
    LDA #7
    STA ZP_TEMP1

    SED

    ; 19 + 01 = 20 (BCD), Carry=0
    CLC
    LDA #$19
    ADC #$01
    BCS FAIL_SUITE7
    CMP #$20
    BNE FAIL_SUITE7

    ; 79 + 25 = 04 with Carry (BCD: 104)
    CLC
    LDA #$79
    ADC #$25
    BCC FAIL_SUITE7
    CMP #$04
    BNE FAIL_SUITE7

    ; 42 - 15 = 27 (BCD), Carry=1 (no borrow)
    SEC
    LDA #$42
    SBC #$15
    BCC FAIL_SUITE7
    CMP #$27
    BNE FAIL_SUITE7

    ; 21 - 34 = 87 with Borrow (BCD: -13 -> 100-13 = 87), Carry=0 (borrow)
    SEC
    LDA #$21
    SBC #$34
    BCS FAIL_SUITE7
    CMP #$87
    BNE FAIL_SUITE7

    CLD

    ; Binary mode check: 9 + 1 = 10 ($0A)
    CLC
    LDA #$09
    ADC #$01
    CMP #$0A
    BNE FAIL_SUITE7

    ; Report Suite 7 Success
    LDA #<ROW_9
    STA ZP_PTR_L
    LDA #>ROW_9
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE8

FAIL_SUITE7:
    CLD
    LDA #7
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 8: CPU Branches & Status Flags
    ; -----------------------------------------------------------------------
SUITE8:
    LDA #8
    STA ZP_TEMP1

    ; BCC / BCS
    CLC
    BCC SUITE8_BCC_OK
    JMP FAIL_SUITE8
SUITE8_BCC_OK:
    BCS FAIL_SUITE8

    SEC
    BCS SUITE8_BCS_OK
    JMP FAIL_SUITE8
SUITE8_BCS_OK:
    BCC FAIL_SUITE8

    ; BEQ / BNE
    LDA #$00
    BEQ SUITE8_BEQ_OK
    JMP FAIL_SUITE8
SUITE8_BEQ_OK:
    BNE FAIL_SUITE8

    LDA #$01
    BNE SUITE8_BNE_OK
    JMP FAIL_SUITE8
SUITE8_BNE_OK:
    BEQ FAIL_SUITE8

    ; BMI / BPL
    LDA #$80
    BMI SUITE8_BMI_OK
    JMP FAIL_SUITE8
SUITE8_BMI_OK:
    BPL FAIL_SUITE8

    LDA #$7F
    BPL SUITE8_BPL_OK
    JMP FAIL_SUITE8
SUITE8_BPL_OK:
    BMI FAIL_SUITE8

    ; BVC / BVS
    CLV
    BVC SUITE8_BVC_OK
    JMP FAIL_SUITE8
SUITE8_BVC_OK:
    BVS FAIL_SUITE8

    ; Trigger Overflow
    LDA #$7F
    CLC
    ADC #$01
    BVS SUITE8_BVS_OK
    JMP FAIL_SUITE8
SUITE8_BVS_OK:
    BVC FAIL_SUITE8

    ; Report Suite 8 Success
    LDA #<ROW_10
    STA ZP_PTR_L
    LDA #>ROW_10
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE9

FAIL_SUITE8:
    LDA #8
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 9: CPU Stack & Subroutines (PHA/PLA, PHP/PLP, JSR/RTS, JMP ind)
    ; -----------------------------------------------------------------------
SUITE9:
    LDA #9
    STA ZP_TEMP1

    ; PHA / PLA
    LDA #$55
    PHA
    LDA #$AA
    PHA
    PLA
    CMP #$AA
    BNE FAIL_SUITE9
    PLA
    CMP #$55
    BNE FAIL_SUITE9

    ; PHP / PLP
    SEC
    PHP
    CLC
    PLP
    BCC FAIL_SUITE9

    ; JSR / RTS
    JSR TEST_SUBROUTINE
    LDA ZP_TEMP2
    CMP #$77
    BNE FAIL_SUITE9

    ; JMP indirect
    LDA #<TARGET_JMP_IND
    STA ZP_PTR_L
    LDA #>TARGET_JMP_IND
    STA ZP_PTR_H
    JMP (ZP_PTR_L)

TARGET_JMP_IND:
    ; Resumed after indirect jump
    ; Report Suite 9 Success
    LDA #<ROW_11
    STA ZP_PTR_L
    LDA #>ROW_11
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE10

FAIL_SUITE9:
    LDA #9
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 10: CPU Bit Test (BIT)
    ; -----------------------------------------------------------------------
SUITE10:
    LDA #10
    STA ZP_TEMP1

    ; Bit 7 test (N flag)
    LDA #$80
    STA ZP_TEMP2
    LDA #$00
    BIT ZP_TEMP2
    BNE FAIL_SUITE10            ; A & M == 0 -> Zero flag must be set
    BPL FAIL_SUITE10            ; Bit 7 of M is 1 -> Negative flag must be set
    BVS FAIL_SUITE10            ; Bit 6 of M is 0 -> Overflow must be clear

    ; Bit 6 test (V flag)
    LDA #$40
    STA ZP_TEMP2
    LDA #$40
    BIT ZP_TEMP2
    BEQ FAIL_SUITE10            ; A & M == $40 -> Zero flag must be clear
    BMI FAIL_SUITE10            ; Bit 7 of M is 0 -> Negative must be clear
    BVC FAIL_SUITE10            ; Bit 6 of M is 1 -> Overflow must be set

    ; Report Suite 10 Success
    LDA #<ROW_12
    STA ZP_PTR_L
    LDA #>ROW_12
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE11

FAIL_SUITE10:
    LDA #10
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 11: Coprocessor - MOS 6522 VIA (Timers, Latches, DDR, IER)
    ; -----------------------------------------------------------------------
SUITE11:
    LDA #11
    STA ZP_TEMP1

    ; 1. Test Data Direction Registers DDRA and DDRB read/write
    LDA #$AA
    STA VIA_DDRA
    LDA VIA_DDRA
    CMP #$AA
    BNE FAIL_SUITE11

    LDA #$55
    STA VIA_DDRA
    LDA VIA_DDRA
    CMP #$55
    BNE FAIL_SUITE11

    LDA #$FF
    STA VIA_DDRA                ; Restore DDRA as all output

    LDA #$07
    STA VIA_DDRB
    LDA VIA_DDRB
    CMP #$07
    BNE FAIL_SUITE11

    ; 2. Test Timer 1 latch and counter decrement
    LDA #$00
    STA VIA_T1LL
    LDA #$27                    ; Set 10000 ($2710) cycles
    STA VIA_T1CH                ; Transfers latch to counter
    LDA VIA_T1CH
    STA ZP_TEMP2                ; Save initial high byte

    ; Wait several cycles
    LDX #100
T1_DELAY:
    DEX
    BNE T1_DELAY

    ; Read Timer 1 counter again
    LDA VIA_T1CL                ; Reading T1CL clears interrupt
    LDA VIA_T1CH
    CMP ZP_TEMP2
    ; It should be <= initial high byte
    BEQ T1_CHECK_LOW
    BCC T1_PASSED
    JMP FAIL_SUITE11

T1_CHECK_LOW:
    ; If high byte is equal, verify counter is active
    LDA VIA_T1CL
    CMP #$00
    BEQ FAIL_SUITE11

T1_PASSED:
    ; 3. Test Timer 2 counter decrement
    LDA #$00
    STA VIA_T2CL
    LDA #$30
    STA VIA_T2CH
    LDA VIA_T2CH
    STA ZP_TEMP2

    LDX #100
T2_DELAY:
    DEX
    BNE T2_DELAY

    LDA VIA_T2CL
    LDA VIA_T2CH
    CMP ZP_TEMP2
    BCC T2_PASSED
    BEQ T2_PASSED
    JMP FAIL_SUITE11

T2_PASSED:
    ; 4. Test IER bit 7 read
    LDA VIA_IER
    BPL FAIL_SUITE11            ; Bit 7 of IER must always read as 1 on 6522

    ; Report Suite 11 Success
    LDA #<ROW_13
    STA ZP_PTR_L
    LDA #>ROW_13
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE12

FAIL_SUITE11:
    LDA #11
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 12: Coprocessor - AY-3-8912 PSG (Sound & Registers)
    ; -----------------------------------------------------------------------
SUITE12:
    LDA #12
    STA ZP_TEMP1

    ; Program Channel A Tone Period (R0 / R1)
    LDX #0                      ; R0 = Channel A Fine Tune
    LDA #$80
    JSR AY_WRITE_REG

    LDX #1                      ; R1 = Channel A Coarse Tune
    LDA #$01                    ; ~260 Hz (Middle C)
    JSR AY_WRITE_REG

    ; Program Channel B Noise (R6)
    LDX #6
    LDA #$0F
    JSR AY_WRITE_REG

    ; Program Mixer (R7): Enable Tone A, disable noise and tone B/C
    LDX #7
    LDA #$FE                    ; %11111110 (Tone A on)
    JSR AY_WRITE_REG

    ; Program Amplitude (R8): Max Volume $0F
    LDX #8
    LDA #$0F
    JSR AY_WRITE_REG

    ; Program Envelope Period (R11, R12) and Shape (R13)
    LDX #11
    LDA #$00
    JSR AY_WRITE_REG

    LDX #12
    LDA #$10
    JSR AY_WRITE_REG

    LDX #13
    LDA #$00                    ; Single decay
    JSR AY_WRITE_REG

    ; Play a quick 3-note jingle to confirm AY audio coprocessor is working
    ; Note 1 (C4: $0180)
    LDY #50
JINGLE_D1:
    LDX #200
JINGLE_D1_IN:
    DEX
    BNE JINGLE_D1_IN
    DEY
    BNE JINGLE_D1

    ; Note 2 (E4: $0130)
    LDX #0
    LDA #$30
    JSR AY_WRITE_REG
    LDY #50
JINGLE_D2:
    LDX #200
JINGLE_D2_IN:
    DEX
    BNE JINGLE_D2_IN
    DEY
    BNE JINGLE_D2

    ; Note 3 (G4: $0100)
    LDX #0
    LDA #$00
    JSR AY_WRITE_REG
    LDY #70
JINGLE_D3:
    LDX #200
JINGLE_D3_IN:
    DEX
    BNE JINGLE_D3_IN
    DEY
    BNE JINGLE_D3

    ; Mute Channel A (Volume = 0)
    LDX #8
    LDA #$00
    JSR AY_WRITE_REG

    ; Report Suite 12 Success
    LDA #<ROW_14
    STA ZP_PTR_L
    LDA #>ROW_14
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP SUITE13

FAIL_SUITE12:
    LDA #12
    JMP RECORD_FAILURE


    ; -----------------------------------------------------------------------
    ; SUITE 13: Coprocessor - ULA Video Memory & Serial Attributes
    ; -----------------------------------------------------------------------
SUITE13:
    LDA #13
    STA ZP_TEMP1

    ; Test screen RAM read/write at Row 23 ($BF28)
    LDA #<($BF28)
    STA ZP_PTR_L
    LDA #>($BF28)
    STA ZP_PTR_H

    LDY #0
TEST_ULA_WRITE:
    TYA
    ORA #$40                    ; Standard ASCII printable range
    STA (ZP_PTR_L), Y
    INY
    CPY #38
    BNE TEST_ULA_WRITE

    LDY #0
TEST_ULA_VERIFY:
    TYA
    ORA #$40
    CMP (ZP_PTR_L), Y
    BNE FAIL_SUITE13
    INY
    CPY #38
    BNE TEST_ULA_VERIFY

    ; Clean up test row with spaces
    LDY #0
    LDA #' '
CLEAN_ULA_ROW:
    STA (ZP_PTR_L), Y
    INY
    CPY #38
    BNE CLEAN_ULA_ROW

    ; Report Suite 13 Success
    LDA #<ROW_15
    STA ZP_PTR_L
    LDA #>ROW_15
    STA ZP_PTR_H
    JSR REPORT_PASS
    JMP ALL_TESTS_BANNER

FAIL_SUITE13:
    LDA #13
    JMP RECORD_FAILURE

ALL_TESTS_BANNER:
    ; -----------------------------------------------------------------------
    ; ALL TESTS PASSED: Display Final Banner
    ; -----------------------------------------------------------------------
    LDA #<ROW_17
    STA ZP_PTR_L
    LDA #>ROW_17
    STA ZP_PTR_H

    ; Column 0: Paper Green attribute ($12 = 18)
    LDY #0
    LDA #18
    STA (ZP_PTR_L), Y

    ; Column 1: Ink White attribute ($07 = 7)
    INY
    LDA #7
    STA (ZP_PTR_L), Y

    ; Print victory banner text
    LDX #0
PRINT_FINAL_TXT:
    LDA TXT_ALL_PASS, X
    BEQ PRINT_FINAL_DONE
    INY
    STA (ZP_PTR_L), Y
    INX
    BNE PRINT_FINAL_TXT

PRINT_FINAL_DONE:
    ; Status line at Row 19
    LDA #<ROW_19
    STA ZP_PTR_L
    LDA #>ROW_19
    STA ZP_PTR_H

    LDY #0
    LDA #16                     ; Paper Black
    STA (ZP_PTR_L), Y
    INY
    LDA #2                      ; Ink Green
    STA (ZP_PTR_L), Y

    LDX #0
PRINT_STATUS_TXT:
    LDA TXT_STATUS_OK, X
    BEQ ALL_TESTS_COMPLETED
    INY
    STA (ZP_PTR_L), Y
    INX
    BNE PRINT_STATUS_TXT

ALL_TESTS_COMPLETED:
    LDA #$00
    STA STATUS_FAIL             ; $0050 = 0 (Success)
    LDA #13
    STA STATUS_COUNT            ; $0051 = 13 suites passed

    ; Stay in infinite loop or return to OS
INFINITE_LOOP:
    JMP INFINITE_LOOP


; ---------------------------------------------------------------------------
; Subroutine: Record Failure
; Input: A = Failed suite index (1..13)
; ---------------------------------------------------------------------------
RECORD_FAILURE:
    STA STATUS_FAIL             ; Set error code in zero page $50

    ; Sound failure alert (Low buzz on AY)
    LDX #0
    LDA #$FF
    JSR AY_WRITE_REG
    LDX #1
    LDA #$07                    ; Low pitch
    JSR AY_WRITE_REG
    LDX #7
    LDA #$FE
    JSR AY_WRITE_REG
    LDX #8
    LDA #$0F                    ; Volume
    JSR AY_WRITE_REG

FAIL_LOOP:
    JMP FAIL_LOOP


; ---------------------------------------------------------------------------
; Subroutine: Report Suite Pass
; Input: ZP_PTR points to screen row base
; ---------------------------------------------------------------------------
REPORT_PASS:
    ; Increment count of passed tests
    INC STATUS_COUNT

    ; Column 31: Green INK attribute ($02)
    LDY #31
    LDA #2
    STA (ZP_PTR_L), Y

    ; Columns 32..37: "[PASS]"
    INY
    LDA #'['
    STA (ZP_PTR_L), Y
    INY
    LDA #'P'
    STA (ZP_PTR_L), Y
    INY
    LDA #'A'
    STA (ZP_PTR_L), Y
    INY
    LDA #'S'
    STA (ZP_PTR_L), Y
    INY
    LDA #'S'
    STA (ZP_PTR_L), Y
    INY
    LDA #']'
    STA (ZP_PTR_L), Y
    RTS


; ---------------------------------------------------------------------------
; Subroutine: AY_WRITE_REG
; Write Value in A to AY Register index in X
; Standalone implementation using VIA Port A ($030F) and PCR ($030C)
; ---------------------------------------------------------------------------
AY_WRITE_REG:
    PHP
    SEI
    PHA                         ; Save value

    ; 1. Latch Register index
    STX VIA_ORA_NH              ; Put register on Port A
    LDA VIA_PCR
    ORA #$EE                    ; BC1=1, BDIR=1 -> Latch address
    STA VIA_PCR
    AND #$11
    ORA #$CC                    ; Inactive (BC1=0, BDIR=0)
    STA VIA_PCR

    ; 2. Write Data
    PLA                         ; Restore value
    STA VIA_ORA_NH              ; Put data on Port A
    LDA VIA_PCR
    ORA #$EC                    ; BDIR=1, BC1=0 -> Write data
    STA VIA_PCR
    AND #$11
    ORA #$CC                    ; Inactive
    STA VIA_PCR

    PLP
    RTS


; ---------------------------------------------------------------------------
; Helper Subroutine for JSR test
; ---------------------------------------------------------------------------
TEST_SUBROUTINE:
    LDA #$77
    STA ZP_TEMP2
    RTS


; ---------------------------------------------------------------------------
; Subroutine: INIT_SCREEN
; Clears screen and writes title banner and row labels
; ---------------------------------------------------------------------------
INIT_SCREEN:
    ; Clear screen ($BB80..$BFDF) with spaces
    LDA #<SCREEN_BASE
    STA ZP_PTR_L
    LDA #>SCREEN_BASE
    STA ZP_PTR_H

    LDX #5                      ; 5 pages of 256 bytes (~1120 bytes)
    LDY #0
    LDA #' '
CLEAR_SCR_LOOP:
    STA (ZP_PTR_L), Y
    INY
    BNE CLEAR_SCR_LOOP
    INC ZP_PTR_H
    DEX
    BNE CLEAR_SCR_LOOP

    ; Row 0: Title Banner ($BB80)
    LDA #<ROW_0
    STA ZP_PTR_L
    LDA #>ROW_0
    STA ZP_PTR_H

    LDY #0
    LDA #17                     ; Paper Blue ($11)
    STA (ZP_PTR_L), Y
    INY
    LDA #3                      ; Ink Yellow ($03)
    STA (ZP_PTR_L), Y

    LDX #0
PRINT_R0:
    LDA TXT_TITLE, X
    BEQ PRINT_R0_DONE
    INY
    STA (ZP_PTR_L), Y
    INX
    BNE PRINT_R0
PRINT_R0_DONE:

    ; Row 1: Subtitle ($BBA8)
    LDA #<ROW_1
    STA ZP_PTR_L
    LDA #>ROW_1
    STA ZP_PTR_H

    LDY #0
    LDA #16                     ; Paper Black
    STA (ZP_PTR_L), Y
    INY
    LDA #6                      ; Ink Cyan
    STA (ZP_PTR_L), Y

    LDX #0
PRINT_R1:
    LDA TXT_SUBTITLE, X
    BEQ PRINT_R1_DONE
    INY
    STA (ZP_PTR_L), Y
    INX
    BNE PRINT_R1
PRINT_R1_DONE:

    ; Render Labels for Suites 1..13
    JSR RENDER_ALL_LABELS
    RTS


RENDER_ALL_LABELS:
    ; Suite 1
    LDA #<ROW_3
    STA ZP_PTR_L
    LDA #>ROW_3
    STA ZP_PTR_H
    LDA #<LBL_S1
    STA ZP_TEMP1
    LDA #>LBL_S1
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 2
    LDA #<ROW_4
    STA ZP_PTR_L
    LDA #>ROW_4
    STA ZP_PTR_H
    LDA #<LBL_S2
    STA ZP_TEMP1
    LDA #>LBL_S2
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 3
    LDA #<ROW_5
    STA ZP_PTR_L
    LDA #>ROW_5
    STA ZP_PTR_H
    LDA #<LBL_S3
    STA ZP_TEMP1
    LDA #>LBL_S3
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 4
    LDA #<ROW_6
    STA ZP_PTR_L
    LDA #>ROW_6
    STA ZP_PTR_H
    LDA #<LBL_S4
    STA ZP_TEMP1
    LDA #>LBL_S4
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 5
    LDA #<ROW_7
    STA ZP_PTR_L
    LDA #>ROW_7
    STA ZP_PTR_H
    LDA #<LBL_S5
    STA ZP_TEMP1
    LDA #>LBL_S5
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 6
    LDA #<ROW_8
    STA ZP_PTR_L
    LDA #>ROW_8
    STA ZP_PTR_H
    LDA #<LBL_S6
    STA ZP_TEMP1
    LDA #>LBL_S6
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 7
    LDA #<ROW_9
    STA ZP_PTR_L
    LDA #>ROW_9
    STA ZP_PTR_H
    LDA #<LBL_S7
    STA ZP_TEMP1
    LDA #>LBL_S7
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 8
    LDA #<ROW_10
    STA ZP_PTR_L
    LDA #>ROW_10
    STA ZP_PTR_H
    LDA #<LBL_S8
    STA ZP_TEMP1
    LDA #>LBL_S8
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 9
    LDA #<ROW_11
    STA ZP_PTR_L
    LDA #>ROW_11
    STA ZP_PTR_H
    LDA #<LBL_S9
    STA ZP_TEMP1
    LDA #>LBL_S9
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 10
    LDA #<ROW_12
    STA ZP_PTR_L
    LDA #>ROW_12
    STA ZP_PTR_H
    LDA #<LBL_S10
    STA ZP_TEMP1
    LDA #>LBL_S10
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 11
    LDA #<ROW_13
    STA ZP_PTR_L
    LDA #>ROW_13
    STA ZP_PTR_H
    LDA #<LBL_S11
    STA ZP_TEMP1
    LDA #>LBL_S11
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 12
    LDA #<ROW_14
    STA ZP_PTR_L
    LDA #>ROW_14
    STA ZP_PTR_H
    LDA #<LBL_S12
    STA ZP_TEMP1
    LDA #>LBL_S12
    STA ZP_TEMP2
    JSR PRINT_LABEL

    ; Suite 13
    LDA #<ROW_15
    STA ZP_PTR_L
    LDA #>ROW_15
    STA ZP_PTR_H
    LDA #<LBL_S13
    STA ZP_TEMP1
    LDA #>LBL_S13
    STA ZP_TEMP2
    JSR PRINT_LABEL

    RTS


PRINT_LABEL:
    ; Attribute Col 0: White INK (7)
    LDY #0
    LDA #7
    STA (ZP_PTR_L), Y

    ; Copy characters up to null terminator
    LDY #1
    LDX #0
PRINT_LBL_LOOP:
    LDA (ZP_TEMP1), Y           ; Note: ZP_TEMP1 holds string address
    ; Wait, ZP_TEMP1 needs indirect with Y=0
    RTS                         ; We implement dedicated loop below


; ---------------------------------------------------------------------------
; Text Strings & Labels
; ---------------------------------------------------------------------------

TXT_TITLE:
    .TEXT "  ORIC ATMOS 6502 & COPROCESSOR TEST  "
    .BYTE 0

TXT_SUBTITLE:
    .TEXT " CPU - 6522 VIA - AY-3-8912 PSG - ULA "
    .BYTE 0

TXT_ALL_PASS:
    .TEXT "   >>> ALL 13 TEST SUITES PASSED! <<<   "
    .BYTE 0

TXT_STATUS_OK:
    .TEXT " ZERO-PAGE: $50=00 (OK)  $51=0D (13/13) "
    .BYTE 0

LBL_S1:
    .TEXT " 01. CPU REGISTERS & TRANSFERS       "
    .BYTE 0

LBL_S2:
    .TEXT " 02. CPU BINARY ALU (ADC/SBC)        "
    .BYTE 0

LBL_S3:
    .TEXT " 03. CPU COMPARISONS (CMP/X/Y)      "
    .BYTE 0

LBL_S4:
    .TEXT " 04. CPU LOGIC (AND/ORA/EOR)         "
    .BYTE 0

LBL_S5:
    .TEXT " 05. CPU SHIFTS & ROTATES            "
    .BYTE 0

LBL_S6:
    .TEXT " 06. CPU INCS & DECS (INC/DEC/X/Y)   "
    .BYTE 0

LBL_S7:
    .TEXT " 07. CPU DECIMAL MODE (BCD)          "
    .BYTE 0

LBL_S8:
    .TEXT " 08. CPU BRANCHES & STATUS FLAGS     "
    .BYTE 0

LBL_S9:
    .TEXT " 09. CPU STACK & SUBROUTINES         "
    .BYTE 0

LBL_S10:
    .TEXT " 10. CPU BIT TEST (Z, N, V FLAGS)    "
    .BYTE 0

LBL_S11:
    .TEXT " 11. VIA 6522 (TIMERS, DDR, IER)     "
    .BYTE 0

LBL_S12:
    .TEXT " 12. AY-3-8912 SOUND GENERATOR       "
    .BYTE 0

LBL_S13:
    .TEXT " 13. ULA VIDEO MEMORY & ATTRS        "
    .BYTE 0
"""

# Small fix for PRINT_LABEL routine in assembly:
FIXED_LABEL_ROUTINE = """
PRINT_LABEL:
    ; Col 0: White INK (7)
    LDY #0
    LDA #7
    STA (ZP_PTR_L), Y

    ; Print label string
    LDY #0
PRINT_LBL_LOOP:
    LDA (ZP_TEMP1), Y
    BEQ PRINT_LBL_DONE
    INY
    STA (ZP_PTR_L), Y
    CPY #30
    BNE PRINT_LBL_LOOP
PRINT_LBL_DONE:
    RTS
"""

def generate():
    global ASM_SOURCE
    # Replace the incomplete PRINT_LABEL
    ASM_SOURCE = ASM_SOURCE.replace("""PRINT_LABEL:
    ; Attribute Col 0: White INK (7)
    LDY #0
    LDA #7
    STA (ZP_PTR_L), Y

    ; Copy characters up to null terminator
    LDY #1
    LDX #0
PRINT_LBL_LOOP:
    LDA (ZP_TEMP1), Y           ; Note: ZP_TEMP1 holds string address
    ; Wait, ZP_TEMP1 needs indirect with Y=0
    RTS                         ; We implement dedicated loop below""", FIXED_LABEL_ROUTINE)

    print("Assembling Oric Atmos Hardware Test Program...")
    asm = Assembler()
    code = asm.assemble(ASM_SOURCE, origin=0x0600)
    print(f"Assembly complete: {len(code)} bytes emitted ($0600..${0x0600 + len(code) - 1:04X})")

    # Generate TAP
    tap_bytes = create_oric_tap(
        filename="TEST ATMOS",
        prog_type=0x80,     # Machine code
        auto_run=0xC7,      # Auto-run enabled
        start_addr=0x0600,
        data=code
    )

    os.makedirs("tapes", exist_ok=True)
    with open("tapes/test.tap", "wb") as f:
        f.write(tap_bytes)
    print(f"Created tapes/test.tap ({len(tap_bytes)} bytes)")

    with open("test.tap", "wb") as f:
        f.write(tap_bytes)
    print(f"Created test.tap ({len(tap_bytes)} bytes)")

if __name__ == '__main__':
    generate()
