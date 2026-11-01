const std = @import("std");

pub const FLAG_CARRY: u8 = 0x01;
pub const FLAG_ZERO: u8 = 0x02;
pub const FLAG_INTERRUPT: u8 = 0x04;
pub const FLAG_DECIMAL: u8 = 0x08;
pub const FLAG_BREAK: u8 = 0x10;
pub const FLAG_UNUSED: u8 = 0x20;
pub const FLAG_OVERFLOW: u8 = 0x40;
pub const FLAG_NEGATIVE: u8 = 0x80;

pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xFD,
    pc: u16 = 0,
    status: u8 = FLAG_UNUSED | FLAG_INTERRUPT,

    cycles: u64 = 0,
    nmi_pending: bool = false,
    irq_pending: bool = false,

    pub fn init() Cpu {
        return .{};
    }

    pub fn reset(self: *Cpu, bus: anytype) void {
        self.a = 0;
        self.x = 0;
        self.y = 0;
        self.sp = 0xFD;
        self.status = FLAG_UNUSED | FLAG_INTERRUPT;

        const low = @as(u16, bus.read(0xFFFC));
        const high = @as(u16, bus.read(0xFFFD));
        self.pc = (high << 8) | low;

        self.cycles = 7;
        self.nmi_pending = false;
        self.irq_pending = false;
    }

    pub fn trigger_nmi(self: *Cpu) void {
        self.nmi_pending = true;
    }

    pub fn trigger_irq(self: *Cpu) void {
        self.irq_pending = true;
    }

    pub fn clear_irq(self: *Cpu) void {
        self.irq_pending = false;
    }

    pub inline fn get_flag(self: *const Cpu, flag: u8) bool {
        return (self.status & flag) != 0;
    }

    pub inline fn set_flag(self: *Cpu, flag: u8, value: bool) void {
        if (value) {
            self.status |= flag;
        } else {
            self.status &= ~flag;
        }
    }

    pub inline fn update_zn(self: *Cpu, val: u8) void {
        self.set_flag(FLAG_ZERO, val == 0);
        self.set_flag(FLAG_NEGATIVE, (val & 0x80) != 0);
    }

    fn push(self: *Cpu, bus: anytype, val: u8) void {
        bus.write(0x0100 | @as(u16, self.sp), val);
        self.sp = self.sp -% 1;
    }

    fn pop(self: *Cpu, bus: anytype) u8 {
        self.sp = self.sp +% 1;
        return bus.read(0x0100 | @as(u16, self.sp));
    }

    fn read_u16(self: *Cpu, bus: anytype, addr: u16) u16 {
        _ = self;
        const low = @as(u16, bus.read(addr));
        const high = @as(u16, bus.read(addr +% 1));
        return (high << 8) | low;
    }

    /// Read 16-bit with 6502 indirect page-wrap bug
    fn read_u16_wrap(self: *Cpu, bus: anytype, addr: u16) u16 {
        _ = self;
        const low = @as(u16, bus.read(addr));
        const high_addr = (addr & 0xFF00) | ((addr +% 1) & 0x00FF);
        const high = @as(u16, bus.read(high_addr));
        return (high << 8) | low;
    }

    /// Execute one instruction and return the number of cycles consumed
    pub fn step(self: *Cpu, bus: anytype) u32 {
        if (self.nmi_pending) {
            self.nmi_pending = false;
            self.handle_nmi(bus);
            return 7;
        }

        if (self.irq_pending and !self.get_flag(FLAG_INTERRUPT)) {
            self.handle_irq(bus);
            return 7;
        }

        const pc = self.pc;
        const opcode = bus.read(pc);
        self.pc = self.pc +% 1;

        const cycles = self.execute_opcode(bus, opcode);
        self.cycles += cycles;
        return cycles;
    }

    fn handle_nmi(self: *Cpu, bus: anytype) void {
        const pc = self.pc;
        self.push(bus, @as(u8, @truncate(pc >> 8)));
        self.push(bus, @as(u8, @truncate(pc & 0xFF)));
        self.push(bus, (self.status & ~FLAG_BREAK) | FLAG_UNUSED);
        self.set_flag(FLAG_INTERRUPT, true);

        const low = @as(u16, bus.read(0xFFFA));
        const high = @as(u16, bus.read(0xFFFB));
        self.pc = (high << 8) | low;
        self.cycles += 7;
    }

    fn handle_irq(self: *Cpu, bus: anytype) void {
        const pc = self.pc;
        self.push(bus, @as(u8, @truncate(pc >> 8)));
        self.push(bus, @as(u8, @truncate(pc & 0xFF)));
        self.push(bus, (self.status & ~FLAG_BREAK) | FLAG_UNUSED);
        self.set_flag(FLAG_INTERRUPT, true);

        const low = @as(u16, bus.read(0xFFFE));
        const high = @as(u16, bus.read(0xFFFF));
        self.pc = (high << 8) | low;
        self.cycles += 7;
    }

    fn branch(self: *Cpu, bus: anytype, condition: bool) u32 {
        const offset = @as(i16, @as(i8, @bitCast(bus.read(self.pc))));
        self.pc = self.pc +% 1;

        if (condition) {
            const old_pc = self.pc;
            const new_pc: u16 = @truncate(@as(u32, @bitCast(@as(i32, old_pc) + offset)));
            self.pc = new_pc;

            // Extra cycle for branch taken, plus 1 more if page crossed
            if ((old_pc & 0xFF00) != (new_pc & 0xFF00)) {
                return 4;
            } else {
                return 3;
            }
        } else {
            return 2;
        }
    }

    fn adc(self: *Cpu, val: u8) void {
        const c: u16 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
        if (self.get_flag(FLAG_DECIMAL)) {
            var al: u16 = (self.a & 0x0F) + (val & 0x0F) + c;
            if (al > 9) {
                al += 6;
            }
            var ah: u16 = (self.a >> 4) + (val >> 4) + (if (al > 0x0F) @as(u16, 1) else 0);
            const binary_sum = @as(u16, self.a) + @as(u16, val) + c;
            const v = (!(((self.a ^ val) & 0x80) != 0)) and ((((self.a ^ @as(u8, @truncate(binary_sum))) & 0x80) != 0));
            self.set_flag(FLAG_OVERFLOW, v);
            self.set_flag(FLAG_NEGATIVE, (binary_sum & 0x80) != 0);
            self.set_flag(FLAG_ZERO, @as(u8, @truncate(binary_sum)) == 0);
            if (ah > 9) {
                ah += 6;
            }
            self.set_flag(FLAG_CARRY, ah > 0x0F);
            self.a = @as(u8, @truncate((ah << 4) | (al & 0x0F)));
        } else {
            const sum = @as(u16, self.a) + @as(u16, val) + c;
            const carry_out = sum > 0xFF;
            const res = @as(u8, @truncate(sum));
            const overflow = (!(((self.a ^ val) & 0x80) != 0)) and ((((self.a ^ res) & 0x80) != 0));
            self.a = res;
            self.set_flag(FLAG_CARRY, carry_out);
            self.set_flag(FLAG_OVERFLOW, overflow);
            self.update_zn(self.a);
        }
    }

    fn sbc(self: *Cpu, val: u8) void {
        const c: u16 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
        const borrow: i16 = 1 - @as(i16, @intCast(c));
        if (self.get_flag(FLAG_DECIMAL)) {
            var al: i16 = @as(i16, self.a & 0x0F) - @as(i16, val & 0x0F) - borrow;
            var ah: i16 = @as(i16, self.a >> 4) - @as(i16, val >> 4);
            if (al < 0) {
                al -= 6;
                ah -= 1;
            }
            if (ah < 0) {
                ah -= 6;
            }
            const diff: i16 = @as(i16, self.a) - @as(i16, val) - borrow;
            const v = (((self.a ^ val) & 0x80) != 0) and (((self.a ^ @as(u8, @truncate(@as(u16, @bitCast(diff))))) & 0x80) != 0);
            self.set_flag(FLAG_CARRY, diff >= 0);
            self.set_flag(FLAG_OVERFLOW, v);
            self.set_flag(FLAG_NEGATIVE, (diff & 0x80) != 0);
            self.set_flag(FLAG_ZERO, @as(u8, @truncate(@as(u16, @bitCast(diff)))) == 0);
            self.a = @as(u8, @truncate(@as(u16, @bitCast((ah << 4) | (al & 0x0F)))));
        } else {
            const diff: i16 = @as(i16, self.a) - @as(i16, val) - borrow;
            const carry_out = diff >= 0;
            const res = @as(u8, @truncate(@as(u16, @bitCast(diff))));
            const overflow = (((self.a ^ val) & 0x80) != 0) and (((self.a ^ res) & 0x80) != 0);
            self.a = res;
            self.set_flag(FLAG_CARRY, carry_out);
            self.set_flag(FLAG_OVERFLOW, overflow);
            self.update_zn(self.a);
        }
    }

    fn compare(self: *Cpu, reg: u8, val: u8) void {
        const diff = @as(i16, reg) - @as(i16, val);
        self.set_flag(FLAG_CARRY, diff >= 0);
        self.update_zn(@as(u8, @truncate(@as(u16, @bitCast(diff)))));
    }

    // Addressing mode helpers
    fn addr_zp(self: *Cpu, bus: anytype) u16 {
        const addr = @as(u16, bus.read(self.pc));
        self.pc = self.pc +% 1;
        return addr;
    }

    fn addr_zpx(self: *Cpu, bus: anytype) u16 {
        const base = bus.read(self.pc);
        self.pc = self.pc +% 1;
        return @as(u16, base +% self.x);
    }

    fn addr_zpy(self: *Cpu, bus: anytype) u16 {
        const base = bus.read(self.pc);
        self.pc = self.pc +% 1;
        return @as(u16, base +% self.y);
    }

    fn addr_abs(self: *Cpu, bus: anytype) u16 {
        const addr = self.read_u16(bus, self.pc);
        self.pc = self.pc +% 2;
        return addr;
    }

    const AddrResult = struct {
        addr: u16,
        page_crossed: bool,
    };

    fn addr_abs_x(self: *Cpu, bus: anytype) AddrResult {
        const base = self.addr_abs(bus);
        const addr = base +% @as(u16, self.x);
        return .{
            .addr = addr,
            .page_crossed = (base & 0xFF00) != (addr & 0xFF00),
        };
    }

    fn addr_abs_y(self: *Cpu, bus: anytype) AddrResult {
        const base = self.addr_abs(bus);
        const addr = base +% @as(u16, self.y);
        return .{
            .addr = addr,
            .page_crossed = (base & 0xFF00) != (addr & 0xFF00),
        };
    }

    fn addr_indx(self: *Cpu, bus: anytype) u16 {
        const base = bus.read(self.pc);
        self.pc = self.pc +% 1;
        const zp = base +% self.x;
        const low = @as(u16, bus.read(@as(u16, zp)));
        const high = @as(u16, bus.read(@as(u16, zp +% 1)));
        return (high << 8) | low;
    }

    fn addr_indy(self: *Cpu, bus: anytype) AddrResult {
        const zp = bus.read(self.pc);
        self.pc = self.pc +% 1;
        const low = @as(u16, bus.read(@as(u16, zp)));
        const high = @as(u16, bus.read(@as(u16, zp +% 1)));
        const base = (high << 8) | low;
        const addr = base +% @as(u16, self.y);
        return .{
            .addr = addr,
            .page_crossed = (base & 0xFF00) != (addr & 0xFF00),
        };
    }

    fn execute_opcode(self: *Cpu, bus: anytype, opcode: u8) u32 {
        switch (opcode) {
            // NOP
            0xEA => return 2,

            // BRK
            0x00 => {
                self.pc = self.pc +% 1;
                const pc = self.pc;
                self.push(bus, @as(u8, @truncate(pc >> 8)));
                self.push(bus, @as(u8, @truncate(pc & 0xFF)));
                self.push(bus, self.status | FLAG_BREAK | FLAG_UNUSED);
                self.set_flag(FLAG_INTERRUPT, true);
                const low = @as(u16, bus.read(0xFFFE));
                const high = @as(u16, bus.read(0xFFFF));
                self.pc = (high << 8) | low;
                return 7;
            },

            // RTI
            0x40 => {
                const status = self.pop(bus);
                self.status = (status & ~FLAG_BREAK) | FLAG_UNUSED;
                const low = @as(u16, self.pop(bus));
                const high = @as(u16, self.pop(bus));
                self.pc = (high << 8) | low;
                return 6;
            },

            // RTS
            0x60 => {
                const low = @as(u16, self.pop(bus));
                const high = @as(u16, self.pop(bus));
                self.pc = ((high << 8) | low) +% 1;
                return 6;
            },

            // JSR
            0x20 => {
                const target = self.addr_abs(bus);
                const ret_pc = self.pc -% 1;
                self.push(bus, @as(u8, @truncate(ret_pc >> 8)));
                self.push(bus, @as(u8, @truncate(ret_pc & 0xFF)));
                self.pc = target;
                return 6;
            },

            // JMP Absolute
            0x4C => {
                self.pc = self.addr_abs(bus);
                return 3;
            },

            // JMP Indirect (with bug)
            0x6C => {
                const addr = self.addr_abs(bus);
                self.pc = self.read_u16_wrap(bus, addr);
                return 5;
            },

            // Flags
            0x18 => { self.set_flag(FLAG_CARRY, false); return 2; },     // CLC
            0x38 => { self.set_flag(FLAG_CARRY, true); return 2; },      // SEC
            0x58 => { self.set_flag(FLAG_INTERRUPT, false); return 2; },  // CLI
            0x78 => { self.set_flag(FLAG_INTERRUPT, true); return 2; },   // SEI
            0xB8 => { self.set_flag(FLAG_OVERFLOW, false); return 2; },   // CLV
            0xD8 => { self.set_flag(FLAG_DECIMAL, false); return 2; },    // CLD
            0xF8 => { self.set_flag(FLAG_DECIMAL, true); return 2; },     // SED

            // Branches
            0x10 => return self.branch(bus, !self.get_flag(FLAG_NEGATIVE)), // BPL
            0x30 => return self.branch(bus, self.get_flag(FLAG_NEGATIVE)),  // BMI
            0x50 => return self.branch(bus, !self.get_flag(FLAG_OVERFLOW)), // BVC
            0x70 => return self.branch(bus, self.get_flag(FLAG_OVERFLOW)),  // BVS
            0x90 => return self.branch(bus, !self.get_flag(FLAG_CARRY)),     // BCC
            0xB0 => return self.branch(bus, self.get_flag(FLAG_CARRY)),      // BCS
            0xD0 => return self.branch(bus, !self.get_flag(FLAG_ZERO)),      // BNE
            0xF0 => return self.branch(bus, self.get_flag(FLAG_ZERO)),       // BEQ

            // LDA
            0xA9 => {
                self.a = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.a);
                return 2;
            },
            0xA5 => {
                const a = self.addr_zp(bus);
                self.a = bus.read(a);
                self.update_zn(self.a);
                return 3;
            },
            0xB5 => {
                const a = self.addr_zpx(bus);
                self.a = bus.read(a);
                self.update_zn(self.a);
                return 4;
            },
            0xAD => {
                const a = self.addr_abs(bus);
                self.a = bus.read(a);
                self.update_zn(self.a);
                return 4;
            },
            0xBD => {
                const res = self.addr_abs_x(bus);
                self.a = bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xB9 => {
                const res = self.addr_abs_y(bus);
                self.a = bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xA1 => {
                const a = self.addr_indx(bus);
                self.a = bus.read(a);
                self.update_zn(self.a);
                return 6;
            },
            0xB1 => {
                const res = self.addr_indy(bus);
                self.a = bus.read(res.addr);
                self.update_zn(self.a);
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // LDX
            0xA2 => {
                self.x = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.x);
                return 2;
            },
            0xA6 => {
                const a = self.addr_zp(bus);
                self.x = bus.read(a);
                self.update_zn(self.x);
                return 3;
            },
            0xB6 => {
                const a = self.addr_zpy(bus);
                self.x = bus.read(a);
                self.update_zn(self.x);
                return 4;
            },
            0xAE => {
                const a = self.addr_abs(bus);
                self.x = bus.read(a);
                self.update_zn(self.x);
                return 4;
            },
            0xBE => {
                const res = self.addr_abs_y(bus);
                self.x = bus.read(res.addr);
                self.update_zn(self.x);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // LDY
            0xA0 => {
                self.y = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.y);
                return 2;
            },
            0xA4 => {
                const a = self.addr_zp(bus);
                self.y = bus.read(a);
                self.update_zn(self.y);
                return 3;
            },
            0xB4 => {
                const a = self.addr_zpx(bus);
                self.y = bus.read(a);
                self.update_zn(self.y);
                return 4;
            },
            0xAC => {
                const a = self.addr_abs(bus);
                self.y = bus.read(a);
                self.update_zn(self.y);
                return 4;
            },
            0xBC => {
                const res = self.addr_abs_x(bus);
                self.y = bus.read(res.addr);
                self.update_zn(self.y);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // STA
            0x85 => { const a = self.addr_zp(bus); bus.write(a, self.a); return 3; },
            0x95 => { const a = self.addr_zpx(bus); bus.write(a, self.a); return 4; },
            0x8D => { const a = self.addr_abs(bus); bus.write(a, self.a); return 4; },
            0x9D => { const res = self.addr_abs_x(bus); bus.write(res.addr, self.a); return 5; },
            0x99 => { const res = self.addr_abs_y(bus); bus.write(res.addr, self.a); return 5; },
            0x81 => { const a = self.addr_indx(bus); bus.write(a, self.a); return 6; },
            0x91 => { const res = self.addr_indy(bus); bus.write(res.addr, self.a); return 6; },

            // STX
            0x86 => { const a = self.addr_zp(bus); bus.write(a, self.x); return 3; },
            0x96 => { const a = self.addr_zpy(bus); bus.write(a, self.x); return 4; },
            0x8E => { const a = self.addr_abs(bus); bus.write(a, self.x); return 4; },

            // STY
            0x84 => { const a = self.addr_zp(bus); bus.write(a, self.y); return 3; },
            0x94 => { const a = self.addr_zpx(bus); bus.write(a, self.y); return 4; },
            0x8C => { const a = self.addr_abs(bus); bus.write(a, self.y); return 4; },

            // Transfer registers
            0xAA => { self.x = self.a; self.update_zn(self.x); return 2; }, // TAX
            0x8A => { self.a = self.x; self.update_zn(self.a); return 2; }, // TXA
            0xA8 => { self.y = self.a; self.update_zn(self.y); return 2; }, // TAY
            0x98 => { self.a = self.y; self.update_zn(self.a); return 2; }, // TYA
            0xBA => { self.x = self.sp; self.update_zn(self.x); return 2; }, // TSX
            0x9A => { self.sp = self.x; return 2; },                        // TXS

            // Stack
            0x48 => { self.push(bus, self.a); return 3; },                 // PHA
            0x68 => { self.a = self.pop(bus); self.update_zn(self.a); return 4; }, // PLA
            0x08 => { self.push(bus, self.status | FLAG_BREAK | FLAG_UNUSED); return 3; }, // PHP
            0x28 => {
                const s = self.pop(bus);
                self.status = (s & ~FLAG_BREAK) | FLAG_UNUSED;
                return 4;
            }, // PLP

            // ADC
            0x69 => {
                const val = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.adc(val);
                return 2;
            },
            0x65 => { const a = self.addr_zp(bus); self.adc(bus.read(a)); return 3; },
            0x75 => { const a = self.addr_zpx(bus); self.adc(bus.read(a)); return 4; },
            0x6D => { const a = self.addr_abs(bus); self.adc(bus.read(a)); return 4; },
            0x7D => {
                const res = self.addr_abs_x(bus);
                self.adc(bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x79 => {
                const res = self.addr_abs_y(bus);
                self.adc(bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x61 => { const a = self.addr_indx(bus); self.adc(bus.read(a)); return 6; },
            0x71 => {
                const res = self.addr_indy(bus);
                self.adc(bus.read(res.addr));
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // SBC
            0xE9 => {
                const val = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.sbc(val);
                return 2;
            },
            0xE5 => { const a = self.addr_zp(bus); self.sbc(bus.read(a)); return 3; },
            0xF5 => { const a = self.addr_zpx(bus); self.sbc(bus.read(a)); return 4; },
            0xED => { const a = self.addr_abs(bus); self.sbc(bus.read(a)); return 4; },
            0xFD => {
                const res = self.addr_abs_x(bus);
                self.sbc(bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xF9 => {
                const res = self.addr_abs_y(bus);
                self.sbc(bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xE1 => { const a = self.addr_indx(bus); self.sbc(bus.read(a)); return 6; },
            0xF1 => {
                const res = self.addr_indy(bus);
                self.sbc(bus.read(res.addr));
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // CMP
            0xC9 => {
                const val = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.compare(self.a, val);
                return 2;
            },
            0xC5 => { const a = self.addr_zp(bus); self.compare(self.a, bus.read(a)); return 3; },
            0xD5 => { const a = self.addr_zpx(bus); self.compare(self.a, bus.read(a)); return 4; },
            0xCD => { const a = self.addr_abs(bus); self.compare(self.a, bus.read(a)); return 4; },
            0xDD => {
                const res = self.addr_abs_x(bus);
                self.compare(self.a, bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xD9 => {
                const res = self.addr_abs_y(bus);
                self.compare(self.a, bus.read(res.addr));
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0xC1 => { const a = self.addr_indx(bus); self.compare(self.a, bus.read(a)); return 6; },
            0xD1 => {
                const res = self.addr_indy(bus);
                self.compare(self.a, bus.read(res.addr));
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // CPX
            0xE0 => {
                const val = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.compare(self.x, val);
                return 2;
            },
            0xE4 => { const a = self.addr_zp(bus); self.compare(self.x, bus.read(a)); return 3; },
            0xEC => { const a = self.addr_abs(bus); self.compare(self.x, bus.read(a)); return 4; },

            // CPY
            0xC0 => {
                const val = bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.compare(self.y, val);
                return 2;
            },
            0xC4 => { const a = self.addr_zp(bus); self.compare(self.y, bus.read(a)); return 3; },
            0xCC => { const a = self.addr_abs(bus); self.compare(self.y, bus.read(a)); return 4; },

            // AND
            0x29 => {
                self.a &= bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.a);
                return 2;
            },
            0x25 => { const a = self.addr_zp(bus); self.a &= bus.read(a); self.update_zn(self.a); return 3; },
            0x35 => { const a = self.addr_zpx(bus); self.a &= bus.read(a); self.update_zn(self.a); return 4; },
            0x2D => { const a = self.addr_abs(bus); self.a &= bus.read(a); self.update_zn(self.a); return 4; },
            0x3D => {
                const res = self.addr_abs_x(bus);
                self.a &= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x39 => {
                const res = self.addr_abs_y(bus);
                self.a &= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x21 => { const a = self.addr_indx(bus); self.a &= bus.read(a); self.update_zn(self.a); return 6; },
            0x31 => {
                const res = self.addr_indy(bus);
                self.a &= bus.read(res.addr);
                self.update_zn(self.a);
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // ORA
            0x09 => {
                self.a |= bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.a);
                return 2;
            },
            0x05 => { const a = self.addr_zp(bus); self.a |= bus.read(a); self.update_zn(self.a); return 3; },
            0x15 => { const a = self.addr_zpx(bus); self.a |= bus.read(a); self.update_zn(self.a); return 4; },
            0x0D => { const a = self.addr_abs(bus); self.a |= bus.read(a); self.update_zn(self.a); return 4; },
            0x1D => {
                const res = self.addr_abs_x(bus);
                self.a |= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x19 => {
                const res = self.addr_abs_y(bus);
                self.a |= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x01 => { const a = self.addr_indx(bus); self.a |= bus.read(a); self.update_zn(self.a); return 6; },
            0x11 => {
                const res = self.addr_indy(bus);
                self.a |= bus.read(res.addr);
                self.update_zn(self.a);
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // EOR
            0x49 => {
                self.a ^= bus.read(self.pc);
                self.pc = self.pc +% 1;
                self.update_zn(self.a);
                return 2;
            },
            0x45 => { const a = self.addr_zp(bus); self.a ^= bus.read(a); self.update_zn(self.a); return 3; },
            0x55 => { const a = self.addr_zpx(bus); self.a ^= bus.read(a); self.update_zn(self.a); return 4; },
            0x4D => { const a = self.addr_abs(bus); self.a ^= bus.read(a); self.update_zn(self.a); return 4; },
            0x5D => {
                const res = self.addr_abs_x(bus);
                self.a ^= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x59 => {
                const res = self.addr_abs_y(bus);
                self.a ^= bus.read(res.addr);
                self.update_zn(self.a);
                return 4 + @as(u32, if (res.page_crossed) 1 else 0);
            },
            0x41 => { const a = self.addr_indx(bus); self.a ^= bus.read(a); self.update_zn(self.a); return 6; },
            0x51 => {
                const res = self.addr_indy(bus);
                self.a ^= bus.read(res.addr);
                self.update_zn(self.a);
                return 5 + @as(u32, if (res.page_crossed) 1 else 0);
            },

            // BIT
            0x24 => {
                const a = self.addr_zp(bus);
                const val = bus.read(a);
                self.set_flag(FLAG_ZERO, (self.a & val) == 0);
                self.set_flag(FLAG_OVERFLOW, (val & 0x40) != 0);
                self.set_flag(FLAG_NEGATIVE, (val & 0x80) != 0);
                return 3;
            },
            0x2C => {
                const a = self.addr_abs(bus);
                const val = bus.read(a);
                self.set_flag(FLAG_ZERO, (self.a & val) == 0);
                self.set_flag(FLAG_OVERFLOW, (val & 0x40) != 0);
                self.set_flag(FLAG_NEGATIVE, (val & 0x80) != 0);
                return 4;
            },

            // INC
            0xE6 => {
                const a = self.addr_zp(bus);
                const val = bus.read(a) +% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0xF6 => {
                const a = self.addr_zpx(bus);
                const val = bus.read(a) +% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0xEE => {
                const a = self.addr_abs(bus);
                const val = bus.read(a) +% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0xFE => {
                const res = self.addr_abs_x(bus);
                const val = bus.read(res.addr) +% 1;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },
            0xE8 => { self.x = self.x +% 1; self.update_zn(self.x); return 2; }, // INX
            0xC8 => { self.y = self.y +% 1; self.update_zn(self.y); return 2; }, // INY

            // DEC
            0xC6 => {
                const a = self.addr_zp(bus);
                const val = bus.read(a) -% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0xD6 => {
                const a = self.addr_zpx(bus);
                const val = bus.read(a) -% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0xCE => {
                const a = self.addr_abs(bus);
                const val = bus.read(a) -% 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0xDE => {
                const res = self.addr_abs_x(bus);
                const val = bus.read(res.addr) -% 1;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },
            0xCA => { self.x = self.x -% 1; self.update_zn(self.x); return 2; }, // DEX
            0x88 => { self.y = self.y -% 1; self.update_zn(self.y); return 2; }, // DEY

            // ASL
            0x0A => {
                self.set_flag(FLAG_CARRY, (self.a & 0x80) != 0);
                self.a = self.a << 1;
                self.update_zn(self.a);
                return 2;
            },
            0x06 => {
                const a = self.addr_zp(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = val << 1;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0x16 => {
                const a = self.addr_zpx(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = val << 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x0E => {
                const a = self.addr_abs(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = val << 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x1E => {
                const res = self.addr_abs_x(bus);
                var val = bus.read(res.addr);
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = val << 1;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },

            // LSR
            0x4A => {
                self.set_flag(FLAG_CARRY, (self.a & 0x01) != 0);
                self.a = self.a >> 1;
                self.update_zn(self.a);
                return 2;
            },
            0x46 => {
                const a = self.addr_zp(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = val >> 1;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0x56 => {
                const a = self.addr_zpx(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = val >> 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x4E => {
                const a = self.addr_abs(bus);
                var val = bus.read(a);
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = val >> 1;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x5E => {
                const res = self.addr_abs_x(bus);
                var val = bus.read(res.addr);
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = val >> 1;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },

            // ROL
            0x2A => {
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
                self.set_flag(FLAG_CARRY, (self.a & 0x80) != 0);
                self.a = (self.a << 1) | c;
                self.update_zn(self.a);
                return 2;
            },
            0x26 => {
                const a = self.addr_zp(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = (val << 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0x36 => {
                const a = self.addr_zpx(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = (val << 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x2E => {
                const a = self.addr_abs(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = (val << 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x3E => {
                const res = self.addr_abs_x(bus);
                var val = bus.read(res.addr);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 1 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x80) != 0);
                val = (val << 1) | c;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },

            // ROR
            0x6A => {
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 0x80 else 0;
                self.set_flag(FLAG_CARRY, (self.a & 0x01) != 0);
                self.a = (self.a >> 1) | c;
                self.update_zn(self.a);
                return 2;
            },
            0x66 => {
                const a = self.addr_zp(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 0x80 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = (val >> 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 5;
            },
            0x76 => {
                const a = self.addr_zpx(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 0x80 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = (val >> 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x6E => {
                const a = self.addr_abs(bus);
                var val = bus.read(a);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 0x80 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = (val >> 1) | c;
                bus.write(a, val);
                self.update_zn(val);
                return 6;
            },
            0x7E => {
                const res = self.addr_abs_x(bus);
                var val = bus.read(res.addr);
                const c: u8 = if (self.get_flag(FLAG_CARRY)) 0x80 else 0;
                self.set_flag(FLAG_CARRY, (val & 0x01) != 0);
                val = (val >> 1) | c;
                bus.write(res.addr, val);
                self.update_zn(val);
                return 7;
            },

            // Unofficial NOPs or unknown opcodes - treat as 2-cycle NOP
            else => return 2,
        }
    }
};

test "cpu reset" {
    const TestBus = struct {
        mem: [65536]u8 = [_]u8{0} ** 65536,
        pub fn read(b: *@This(), addr: u16) u8 { return b.mem[addr]; }
        pub fn write(b: *@This(), addr: u16, val: u8) void { b.mem[addr] = val; }
    };
    var bus = TestBus{};
    bus.write(0xFFFC, 0x00);
    bus.write(0xFFFD, 0x80);

    var cpu = Cpu.init();
    cpu.reset(&bus);

    try std.testing.expectEqual(@as(u16, 0x8000), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0xFD), cpu.sp);
    try std.testing.expect(cpu.get_flag(FLAG_INTERRUPT));
}

test "cpu adc sbc decimal" {
    var cpu = Cpu.init();
    cpu.set_flag(FLAG_DECIMAL, true);

    // ADC test: 0x79 + 0x23 + 0 (carry=0) = 0x02 with carry=1 in BCD
    cpu.set_flag(FLAG_CARRY, false);
    cpu.a = 0x79;
    cpu.adc(0x23);
    try std.testing.expectEqual(@as(u8, 0x02), cpu.a);
    try std.testing.expect(cpu.get_flag(FLAG_CARRY));

    // SBC test: 0x25 - 0x19 with carry=1 (no borrow) = 0x06
    cpu.set_flag(FLAG_CARRY, true);
    cpu.a = 0x25;
    cpu.sbc(0x19);
    try std.testing.expectEqual(@as(u8, 0x06), cpu.a);
    try std.testing.expect(cpu.get_flag(FLAG_CARRY));
}
