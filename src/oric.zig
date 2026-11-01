const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const cpu_mod = @import("cpu.zig");
const SystemBus = @import("bus.zig").SystemBus;
const OricModel = @import("bus.zig").OricModel;
const Tape = @import("tape.zig").Tape;

pub const CYCLES_PER_FRAME: u32 = 20_000; // 1,000,000 Hz / 50 Hz = 20,000 cycles per frame

pub const Oric = struct {
    cpu: Cpu,
    bus: SystemBus,
    tape: Tape,
    warp_mode: bool = false,
    paused: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, model: OricModel, custom_rom: ?[]const u8) Oric {
        var bus = SystemBus.init(model, custom_rom);
        var cpu = Cpu.init();
        cpu.reset(&bus);

        return .{
            .cpu = cpu,
            .bus = bus,
            .tape = Tape.init(allocator),
            .warp_mode = false,
            .paused = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Oric) void {
        self.tape.deinit();
    }

    pub fn reset(self: *Oric) void {
        self.bus.reset();
        self.cpu.reset(&self.bus);
    }

    pub fn set_model(self: *Oric) void {
        self.bus.set_model(self.bus.model);
        self.cpu.reset(&self.bus);
    }

    pub fn switch_model(self: *Oric, model: OricModel) void {
        self.bus.set_model(model);
        self.cpu.reset(&self.bus);
    }

    /// Load and inject a .TAP file into the emulator
    pub fn load_tape_file(self: *Oric, path: []const u8, auto_run: bool) ![]u8 {
        const count = try self.tape.load_file(path);
        const inject = try self.tape.fast_inject(&self.bus.ram);

        const filename = if (self.tape.loaded_filename) |f| f else "tape";
        const type_str = if (inject.is_mc) "Machine Code" else "BASIC";

        const info = try std.fmt.allocPrint(
            self.allocator,
            "Loaded '{s}' ({d} block(s), start: ${X:0>4}, type: {s})",
            .{ filename, count, inject.start_addr, type_str },
        );

        if (auto_run or inject.auto_run) {
            if (inject.is_mc) {
                // For machine code, jump directly to start address
                self.cpu.pc = inject.start_addr;
            } else {
                // For BASIC, type RUN
                self.bus.keyboard.queue_string("RUN\r");
            }
        }

        return info;
    }

    /// Fast-load trap for Oric tape routines (TAPESYNC & GETTAPEBYTE)
    fn check_tape_trap(self: *Oric) bool {
        if (self.tape.raw_bytes.len == 0) {
            return false;
        }

        const sync_pc: u16 = switch (self.bus.model) {
            .atmos => 0xE735,
            .oric1 => 0xE696,
        };

        const byte_pc: u16 = switch (self.bus.model) {
            .atmos => 0xE6C9,
            .oric1 => 0xE630,
        };

        if (self.cpu.pc == sync_pc) {
            // TAPESYNC: Search next 0x16 sync byte in raw_bytes
            while (self.tape.raw_pos < self.tape.raw_bytes.len and self.tape.raw_bytes[self.tape.raw_pos] != 0x16) {
                self.tape.raw_pos += 1;
            }
            self.bus.ram[0x2F] = 0x16;

            // Simulate RTS
            self.cpu.sp = self.cpu.sp +% 1;
            const low = @as(u16, self.bus.read(0x0100 | @as(u16, self.cpu.sp)));
            self.cpu.sp = self.cpu.sp +% 1;
            const high = @as(u16, self.bus.read(0x0100 | @as(u16, self.cpu.sp)));
            self.cpu.pc = ((high << 8) | low) +% 1;
            return true;
        }

        if (self.cpu.pc == byte_pc) {
            // GETTAPEBYTE: Fetch next tape byte into Accumulator
            const b: u8 = if (self.tape.raw_pos < self.tape.raw_bytes.len) blk: {
                const byte = self.tape.raw_bytes[self.tape.raw_pos];
                self.tape.raw_pos += 1;
                break :blk byte;
            } else 0xFF;

            self.cpu.a = b;
            self.bus.ram[0x2F] = b;
            self.cpu.set_flag(cpu_mod.FLAG_ZERO, b == 0);
            self.cpu.set_flag(cpu_mod.FLAG_NEGATIVE, (b & 0x80) != 0);
            self.cpu.set_flag(cpu_mod.FLAG_CARRY, false);

            // Simulate RTS
            self.cpu.sp = self.cpu.sp +% 1;
            const low = @as(u16, self.bus.read(0x0100 | @as(u16, self.cpu.sp)));
            self.cpu.sp = self.cpu.sp +% 1;
            const high = @as(u16, self.bus.read(0x0100 | @as(u16, self.cpu.sp)));
            self.cpu.pc = ((high << 8) | low) +% 1;
            return true;
        }

        return false;
    }

    /// Run one 50Hz frame (~20,000 CPU cycles at 1 MHz)
    pub fn step_frame(self: *Oric) void {
        if (self.paused) {
            return;
        }

        var frame_cycles: u32 = 0;
        while (frame_cycles < CYCLES_PER_FRAME) {
            // Synchronize IRQ line between VIA and CPU
            if (self.bus.via.irq_asserted) {
                self.cpu.trigger_irq();
            } else {
                self.cpu.clear_irq();
            }

            // Check tape fast-load traps
            if (self.check_tape_trap()) {
                self.bus.via.step(6);
                self.bus.ay.step(6);
                frame_cycles += 6;
                continue;
            }

            const cycles = self.cpu.step(&self.bus);
            self.bus.via.step(cycles);
            self.bus.ay.step(cycles);

            frame_cycles += cycles;
        }

        // Process keyboard auto-typein
        self.bus.keyboard.step_typein();

        // Render video frame
        self.bus.video.render_frame(&self.bus.ram);
    }
};
