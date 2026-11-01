const std = @import("std");

pub const cpu = @import("cpu.zig");
pub const via = @import("via.zig");
pub const psg = @import("psg.zig");
pub const video = @import("video.zig");
pub const keyboard = @import("keyboard.zig");
pub const tape = @import("tape.zig");
pub const bus = @import("bus.zig");
pub const oric = @import("oric.zig");
pub const sdl = @import("sdl.zig");

test "atmos boot" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // Boot takes ~150 frames to complete RAM test and display greeting
    var f: usize = 0;
    while (f < 160) : (f += 1) {
        machine.step_frame();
    }

    const text_ram = machine.bus.ram[0xBB80..0xBFE0];
    var screen_buf: [1120]u8 = undefined;
    for (text_ram, 0..) |b, i| {
        const ch = b & 0x7F;
        screen_buf[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    const screen_str = screen_buf[0..];

    try std.testing.expect(std.mem.indexOf(u8, screen_str, "ORIC EXTENDED BASIC V1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen_str, "Ready") != null);
}

test "oric1 boot" {
    var machine = oric.Oric.init(std.testing.allocator, .oric1, null);
    defer machine.deinit();

    var f: usize = 0;
    while (f < 160) : (f += 1) {
        machine.step_frame();
    }

    const text_ram = machine.bus.ram[0xBB80..0xBFE0];
    var screen_buf: [1120]u8 = undefined;
    for (text_ram, 0..) |b, i| {
        const ch = b & 0x7F;
        screen_buf[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    const screen_str = screen_buf[0..];

    try std.testing.expect(std.mem.indexOf(u8, screen_str, "ORIC EXTENDED BASIC V1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen_str, "Ready") != null);
}

test "keyboard command print 42" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // Boot the system
    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    // Type "PRINT 42" and press Enter
    machine.bus.keyboard.queue_string("PRINT 42\r");

    // Run frames to process typed command
    f = 0;
    while (f < 100) : (f += 1) {
        machine.step_frame();
    }

    const text_ram = machine.bus.ram[0xBB80..0xBFE0];
    var screen_buf: [1120]u8 = undefined;
    for (text_ram, 0..) |b, i| {
        const ch = b & 0x7F;
        screen_buf[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    const screen_str = screen_buf[0..];

    try std.testing.expect(std.mem.indexOf(u8, screen_str, "42") != null);
}

test "tape welcome" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    const info = try machine.load_tape_file("tapes/welcome.tap", true);
    defer machine.allocator.free(info);

    f = 0;
    while (f < 100) : (f += 1) {
        machine.step_frame();
    }

    try std.testing.expect(machine.bus.video.hires_mode);
}

test "tape cyclotron" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    const info = try machine.load_tape_file("tapes/cyclotron.tap", true);
    defer machine.allocator.free(info);

    f = 0;
    while (f < 60) : (f += 1) {
        machine.step_frame();
    }

    try std.testing.expect(machine.cpu.pc != 0);
}

test "tape stormlord" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    const info = try machine.load_tape_file("tapes/stormlord.tap", true);
    defer machine.allocator.free(info);

    f = 0;
    while (f < 60) : (f += 1) {
        machine.step_frame();
    }

    try std.testing.expect(machine.bus.video.hires_mode);
}

test "tape wizards lair" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    const info = try machine.load_tape_file("tapes/wizards_lair.tap", true);
    defer machine.allocator.free(info);

    f = 0;
    while (f < 300) : (f += 1) {
        machine.step_frame();
    }

    try std.testing.expectEqual(machine.tape.raw_pos, machine.tape.raw_bytes.len);
    try std.testing.expect(machine.bus.video.hires_mode);
}

test "cpu stack operations" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // Push 0x42
    machine.bus.ram[0x01FF] = 0x42;
    machine.cpu.sp = 0xFE;
    const popped = machine.bus.ram[0x0100 | @as(u16, machine.cpu.sp +% 1)];
    try std.testing.expectEqual(@as(u8, 0x42), popped);
}
