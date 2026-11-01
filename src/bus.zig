const std = @import("std");
const Via6522 = @import("via.zig").Via6522;
const Ay38912 = @import("psg.zig").Ay38912;
const Keyboard = @import("keyboard.zig").Keyboard;
const Video = @import("video.zig").Video;
const video_mod = @import("video.zig");

pub const EMBEDDED_ATMOS_ROM = @embedFile("roms/atmos.rom");
pub const EMBEDDED_ORIC1_ROM = @embedFile("roms/oric1.rom");

pub const OricModel = enum {
    atmos,
    oric1,
};

pub const SystemBus = struct {
    ram: [49152]u8 = [_]u8{0} ** 49152, // 48 KB RAM ($0000..$BFFF)
    rom: []const u8,
    custom_rom: ?[]const u8 = null,
    via: Via6522,
    ay: Ay38912,
    keyboard: Keyboard,
    video: Video,
    model: OricModel,

    pub fn init(model: OricModel, custom_rom: ?[]const u8) SystemBus {
        const rom_slice = if (custom_rom) |r|
            r
        else switch (model) {
            .atmos => EMBEDDED_ATMOS_ROM,
            .oric1 => EMBEDDED_ORIC1_ROM,
        };

        var bus = SystemBus{
            .rom = rom_slice,
            .custom_rom = custom_rom,
            .via = Via6522.init(),
            .ay = Ay38912.init(44100),
            .keyboard = Keyboard.init(),
            .video = Video.init(),
            .model = model,
        };

        bus.reset();
        return bus;
    }

    pub fn reset(self: *SystemBus) void {
        @memset(&self.ram, 0);
        self.via.reset();
        self.ay.reset();
        self.keyboard.reset();
        self.video.reset();

        // Preload standard font into RAM at $B400 so text is displayed immediately
        const font_dest = 0xB400 + (32 * 8);
        if (font_dest + video_mod.ORIC_FONT_STANDARD.len <= self.ram.len) {
            @memcpy(
                self.ram[font_dest .. font_dest + video_mod.ORIC_FONT_STANDARD.len],
                &video_mod.ORIC_FONT_STANDARD,
            );
        }
    }

    pub fn set_model(self: *SystemBus, model: OricModel) void {
        self.model = model;
        if (self.custom_rom) |r| {
            self.rom = r;
        } else {
            self.rom = switch (model) {
                .atmos => EMBEDDED_ATMOS_ROM,
                .oric1 => EMBEDDED_ORIC1_ROM,
            };
        }
        self.reset();
    }

    pub fn read(self: *SystemBus, addr: u16) u8 {
        switch (addr) {
            // $0000..$02FF: RAM
            0x0000...0x02FF => return self.ram[addr],

            // $0300..$03FF: I/O (VIA 6522 registers)
            0x0300...0x03FF => {
                const reg: u8 = @truncate(addr & 0x0F);
                return self.via.read(reg, &self.ay, &self.keyboard);
            },

            // $0400..$BFFF: RAM
            0x0400...0xBFFF => return self.ram[addr],

            // $C000..$FFFF: ROM
            0xC000...0xFFFF => {
                const offset: usize = addr - 0xC000;
                if (offset < self.rom.len) {
                    return self.rom[offset];
                } else {
                    return 0xFF;
                }
            },
        }
    }

    pub fn write(self: *SystemBus, addr: u16, val: u8) void {
        switch (addr) {
            // $0000..$02FF: RAM
            0x0000...0x02FF => {
                self.ram[addr] = val;
            },

            // $0300..$03FF: I/O (VIA 6522 registers)
            0x0300...0x03FF => {
                const reg: u8 = @truncate(addr & 0x0F);
                self.via.write(reg, val, &self.ay);
            },

            // $0400..$BFFF: RAM
            0x0400...0xBFFF => {
                self.ram[addr] = val;
            },

            // $C000..$FFFF: ROM (read-only on standard hardware)
            0xC000...0xFFFF => {},
        }
    }
};
