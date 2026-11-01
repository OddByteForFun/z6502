const std = @import("std");
const Ay38912 = @import("psg.zig").Ay38912;
const Keyboard = @import("keyboard.zig").Keyboard;

pub const Via6522 = struct {
    orb: u8 = 0,
    ora: u8 = 0,
    ddrb: u8 = 0,
    ddra: u8 = 0,

    t1c: u16 = 0x2710, // 10,000 cycles (~100 Hz at 1 MHz)
    t1l: u16 = 0x2710,
    t1_active: bool = true,

    t2c: u16 = 0xFFFF,
    t2l: u16 = 0xFFFF,
    t2_active: bool = true,

    sr: u8 = 0,
    acr: u8 = 0,
    pcr: u8 = 0xCC,
    ifr: u8 = 0,
    ier: u8 = 0x40, // Timer 1 interrupt enabled by default

    irq_asserted: bool = false,

    pub fn init() Via6522 {
        var via = Via6522{};
        via.update_irq();
        return via;
    }

    pub fn reset(self: *Via6522) void {
        self.orb = 0;
        self.ora = 0;
        self.ddrb = 0;
        self.ddra = 0;
        self.t1c = 0x2710;
        self.t1l = 0x2710;
        self.t1_active = true;
        self.t2c = 0xFFFF;
        self.t2l = 0xFFFF;
        self.t2_active = true;
        self.sr = 0;
        self.acr = 0;
        self.pcr = 0xCC;
        self.ifr = 0;
        self.ier = 0x40;
        self.irq_asserted = false;
        self.update_irq();
    }

    pub inline fn update_irq(self: *Via6522) void {
        self.irq_asserted = (self.ifr & self.ier & 0x7F) != 0;
    }

    pub fn read(self: *Via6522, reg: u8, ay: *const Ay38912, keyboard: *const Keyboard) u8 {
        switch (reg & 0x0F) {
            // 0x00: Port B
            0x00 => {
                self.ifr &= ~@as(u8, 0x10); // Clear CB1 interrupt flag
                self.update_irq();

                const row = self.orb & 0x07;
                const ay_port_a = ay.regs[14];
                const key_sense = keyboard.read_bit(row, ay_port_a);

                return (self.orb & ~@as(u8, 0x08)) | key_sense;
            },

            // 0x01 / 0x0F: Port A
            0x01, 0x0F => {
                const bc1 = (self.pcr & 0x0E) == 0x0E;
                const bdir = (self.pcr & 0xE0) == 0xE0;

                // Read from AY register if BC1=1 and BDIR=0
                if (bc1 and !bdir) {
                    return ay.read_reg(ay.selected_reg & 0x0F);
                } else {
                    return (self.ora & self.ddra) | (~self.ddra & 0xFF);
                }
            },

            // 0x02: DDRB
            0x02 => return self.ddrb,

            // 0x03: DDRA
            0x03 => return self.ddra,

            // 0x04: T1C-L
            0x04 => {
                self.ifr &= ~@as(u8, 0x40); // Clear T1 interrupt flag
                self.update_irq();
                return @as(u8, @truncate(self.t1c & 0xFF));
            },

            // 0x05: T1C-H
            0x05 => return @as(u8, @truncate((self.t1c >> 8) & 0xFF)),

            // 0x06: T1L-L
            0x06 => return @as(u8, @truncate(self.t1l & 0xFF)),

            // 0x07: T1L-H
            0x07 => return @as(u8, @truncate((self.t1l >> 8) & 0xFF)),

            // 0x08: T2C-L
            0x08 => {
                self.ifr &= ~@as(u8, 0x20); // Clear T2 interrupt flag
                self.update_irq();
                return @as(u8, @truncate(self.t2c & 0xFF));
            },

            // 0x09: T2C-H
            0x09 => return @as(u8, @truncate((self.t2c >> 8) & 0xFF)),

            // 0x0A: Shift Register
            0x0A => return self.sr,

            // 0x0B: ACR
            0x0B => return self.acr,

            // 0x0C: PCR
            0x0C => return self.pcr,

            // 0x0D: IFR
            0x0D => {
                const composite: u8 = if ((self.ifr & self.ier & 0x7F) != 0) 0x80 else 0x00;
                return self.ifr | composite;
            },

            // 0x0E: IER
            0x0E => return self.ier | 0x80,

            else => return 0xFF,
        }
    }

    pub fn write(self: *Via6522, reg: u8, val: u8, ay: *Ay38912) void {
        switch (reg & 0x0F) {
            // 0x00: Port B
            0x00 => {
                self.orb = val;
                self.ifr &= ~@as(u8, 0x10); // Clear CB1 interrupt flag
            },

            // 0x01 / 0x0F: Port A
            0x01, 0x0F => {
                self.ora = val;
                self.ay_check_control(ay);
            },

            // 0x02: DDRB
            0x02 => self.ddrb = val,

            // 0x03: DDRA
            0x03 => self.ddra = val,

            // 0x04: T1L-L
            0x04 => {
                self.t1l = (self.t1l & 0xFF00) | @as(u16, val);
            },

            // 0x05: T1C-H (transfers latch to counter and clears T1 interrupt)
            0x05 => {
                self.t1l = (self.t1l & 0x00FF) | (@as(u16, val) << 8);
                self.t1c = self.t1l;
                self.ifr &= ~@as(u8, 0x40);
                self.t1_active = true;
            },

            // 0x06: T1L-L
            0x06 => {
                self.t1l = (self.t1l & 0xFF00) | @as(u16, val);
            },

            // 0x07: T1L-H
            0x07 => {
                self.t1l = (self.t1l & 0x00FF) | (@as(u16, val) << 8);
                self.ifr &= ~@as(u8, 0x40);
            },

            // 0x08: T2L-L
            0x08 => {
                self.t2l = (self.t2l & 0xFF00) | @as(u16, val);
            },

            // 0x09: T2C-H
            0x09 => {
                self.t2l = (self.t2l & 0x00FF) | (@as(u16, val) << 8);
                self.t2c = self.t2l;
                self.ifr &= ~@as(u8, 0x20);
                self.t2_active = true;
            },

            // 0x0A: Shift Register
            0x0A => self.sr = val,

            // 0x0B: ACR
            0x0B => self.acr = val,

            // 0x0C: PCR
            0x0C => {
                self.pcr = val;
                self.ay_check_control(ay);
            },

            // 0x0D: IFR (writing 1 clears corresponding bit)
            0x0D => {
                self.ifr &= ~(val & 0x7F);
            },

            // 0x0E: IER (bit 7 sets or clears enabled bits)
            0x0E => {
                if ((val & 0x80) != 0) {
                    self.ier |= val & 0x7F;
                    // Protect against corrupted/too-small timer values that would asphyxiate the CPU
                    if ((val & 0x40) != 0 and self.t1l < 1000) {
                        self.t1l = 10000;
                        self.t1c = 10000;
                        self.ifr &= ~@as(u8, 0x40);
                    }
                } else {
                    self.ier &= ~(val & 0x7F);
                }
            },

            else => {},
        }

        self.update_irq();
    }

    /// Check CA2 / CB2 signals to drive AY-3-8912 operations
    pub fn ay_check_control(self: *Via6522, ay: *Ay38912) void {
        const bc1 = (self.pcr & 0x0E) == 0x0E;
        const bdir = (self.pcr & 0xE0) == 0xE0;

        if (bc1 and bdir) {
            // Latch register address
            ay.selected_reg = self.ora & 0x0F;
        } else if (!bc1 and bdir) {
            // Write to selected register
            ay.write_reg(ay.selected_reg, self.ora);
        }
    }

    /// Step VIA timers by a number of CPU cycles
    pub fn step(self: *Via6522, cycles: u32) void {
        if (self.t1_active) {
            if (@as(u32, self.t1c) <= cycles) {
                self.ifr |= 0x40; // Set T1 interrupt flag

                // Continuous reload mode from latch
                const reload: u32 = if (self.t1l < 1000) 10000 else @as(u32, self.t1l);
                const underflow = cycles - @as(u32, self.t1c);
                self.t1c = @as(u16, @truncate(reload - (underflow % reload)));
            } else {
                self.t1c -= @as(u16, @truncate(cycles));
            }
        }

        if (self.t2_active) {
            if (@as(u32, self.t2c) <= cycles) {
                self.ifr |= 0x20; // Set T2 interrupt flag
                const underflow = cycles - @as(u32, self.t2c);
                self.t2c = @as(u16, @truncate(0xFFFF - (underflow % 0xFFFF)));
            } else {
                self.t2c -= @as(u16, @truncate(cycles));
            }
        }

        self.update_irq();
    }
};
