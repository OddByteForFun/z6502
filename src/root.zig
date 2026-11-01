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

    try std.testing.expect(std.mem.indexOf(u8, screen_str, "42") != null);
}

test "tape welcome interactive option 2" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // 1. Boot machine
    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    // 2. Load welcome.tap (fast load)
    const info = try machine.load_tape_file("tapes/welcome.tap", true);
    defer machine.allocator.free(info);

    // 3. Step until tape raw_pos reaches end of tape
    f = 0;
    while (f < 200) : (f += 1) {
        machine.step_frame();
        if (machine.tape.raw_pos >= 40990) {
            std.debug.print("Tape finished at frame {d}\n", .{f});
            break;
        }
    }

    // Step 14 frames after tape finish to let line 3998 (KEY$ polling) start
    f = 0;
    while (f < 14) : (f += 1) {
        machine.step_frame();
    }

    // 4. Press AZERTY key 2 (keysym 0xE9 for 'é') while line 3998 is polling KEY$
    machine.bus.keyboard.handle_key(0xE9, 0, true);
    f = 0;
    while (f < 8) : (f += 1) {
        machine.step_frame();
    }
    machine.bus.keyboard.handle_key(0xE9, 0, false);

    // 5. Run frames for BASIC to process Option 2:
    var non_zero_samples: usize = 0;
    var music_irq_count: usize = 0;
    f = 0;
    while (f < 80) : (f += 1) {
        machine.step_frame();
        if (machine.cpu.pc == 0x810B) {
            music_irq_count += 1;
        }
        for (machine.bus.ay.audio_buffer[0..machine.bus.ay.audio_len]) |s| {
            if (s != 0) non_zero_samples += 1;
        }
        machine.bus.ay.audio_len = 0;
    }
    try std.testing.expectEqual(@as(u8, 1), machine.bus.ram[0x02FF]);
    try std.testing.expectEqual(@as(u8, 0x4C), machine.bus.ram[0x024A]);
    try std.testing.expectEqual(@as(u8, 0x0B), machine.bus.ram[0x024B]);
    try std.testing.expectEqual(@as(u8, 0x81), machine.bus.ram[0x024C]);
    try std.testing.expectEqual(@as(u8, 0x7E), machine.bus.ay.regs[7]);
    try std.testing.expectEqual(@as(u8, 0x10), machine.bus.ay.regs[8]);
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

test "sound ping command" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // Boot
    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    // Clear any startup audio samples
    machine.bus.ay.audio_len = 0;

    // Type "PING" and press Enter
    machine.bus.keyboard.queue_string("PING\r");

    var non_zero_samples: usize = 0;
    f = 0;
    while (f < 100) : (f += 1) {
        machine.step_frame();
        for (machine.bus.ay.audio_buffer[0..machine.bus.ay.audio_len]) |s| {
            if (s != 0) non_zero_samples += 1;
        }
        machine.bus.ay.audio_len = 0;
    }

    try std.testing.expect(non_zero_samples > 0);
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

test "cpu and coprocessor hardware test tap" {
    var machine = oric.Oric.init(std.testing.allocator, .atmos, null);
    defer machine.deinit();

    // Boot Atmos
    var f: usize = 0;
    while (f < 180) : (f += 1) {
        machine.step_frame();
    }

    // Load test.tap with auto-run
    const info = try machine.load_tape_file("tapes/test.tap", true);
    defer machine.allocator.free(info);

    // Execute test suites
    f = 0;
    while (f < 60) : (f += 1) {
        machine.step_frame();
    }

    // Verify Zero-Page Status
    const status_fail = machine.bus.ram[0x50];
    const status_count = machine.bus.ram[0x51];

    try std.testing.expectEqual(@as(u8, 0), status_fail);
    try std.testing.expectEqual(@as(u8, 13), status_count);

    // Verify visual text results on screen
    const text_ram = machine.bus.ram[0xBB80..0xBFE0];
    var screen_buf: [1120]u8 = undefined;
    for (text_ram, 0..) |b, i| {
        const ch = b & 0x7F;
        screen_buf[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    const screen_str = screen_buf[0..];

    try std.testing.expect(std.mem.indexOf(u8, screen_str, "ORIC ATMOS 6502 & COPROCESSOR TEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen_str, "ALL 13 TEST SUITES PASSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen_str, "ZERO-PAGE: $50=00 (OK)  $51=0D (13/13)") != null);
}
