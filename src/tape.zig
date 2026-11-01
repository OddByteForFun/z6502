const std = @import("std");

pub const TapBlock = struct {
    prog_type: u8, // 0x00 = BASIC, 0x80 = Machine Code
    auto_run: u8, // 0x00 = No, 0xC7 = Auto-run
    start_addr: u16,
    end_addr: u16,
    name: []const u8,
    data: []const u8,
};

const FILE = anyopaque;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fclose(stream: *FILE) c_int;

pub const Tape = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(TapBlock) = .empty,
    raw_bytes: []u8 = &[_]u8{},
    raw_pos: usize = 0,
    loaded_filename: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Tape {
        return .{
            .allocator = allocator,
            .blocks = .empty,
        };
    }

    pub fn deinit(self: *Tape) void {
        self.blocks.deinit(self.allocator);
        if (self.raw_bytes.len > 0) {
            self.allocator.free(self.raw_bytes);
            self.raw_bytes = &[_]u8{};
        }
        if (self.loaded_filename) |name| {
            self.allocator.free(name);
            self.loaded_filename = null;
        }
    }

    pub fn rewind(self: *Tape) void {
        self.raw_pos = 0;
    }

    pub fn has_data(self: *const Tape) bool {
        return self.raw_pos < self.raw_bytes.len;
    }

    /// Load a .TAP file from disk and parse all blocks
    pub fn load_file(self: *Tape, path: []const u8) !usize {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const f = fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
        defer _ = fclose(f);

        _ = fseek(f, 0, 2); // SEEK_END
        const file_len: usize = @intCast(ftell(f));
        _ = fseek(f, 0, 0); // SEEK_SET

        const buffer = try self.allocator.alloc(u8, file_len);
        errdefer self.allocator.free(buffer);

        const read_len = fread(buffer.ptr, 1, file_len, f);
        if (read_len != file_len) {
            return error.FileReadError;
        }

        if (self.raw_bytes.len > 0) {
            self.allocator.free(self.raw_bytes);
        }
        self.raw_bytes = buffer;
        self.raw_pos = 0;

        self.blocks.clearRetainingCapacity();
        try self.parse_tap_bytes(buffer);

        if (self.loaded_filename) |name| {
            self.allocator.free(name);
        }
        const basename = std.fs.path.basename(path);
        self.loaded_filename = try self.allocator.dupe(u8, basename);

        return self.blocks.items.len;
    }

    /// Parse bytes of a .TAP file into blocks
    pub fn parse_tap_bytes(self: *Tape, bytes: []const u8) !void {
        var pos: usize = 0;

        while (pos < bytes.len) {
            // Find sync sequence: 0x16 0x16 0x16 0x24 (or 0x16* + 0x24)
            var sync_found = false;
            while (pos < bytes.len) {
                if (bytes[pos] == 0x24 and pos >= 1 and bytes[pos - 1] == 0x16) {
                    sync_found = true;
                    pos += 1;
                    break;
                }
                pos += 1;
            }

            if (!sync_found or pos + 9 > bytes.len) {
                break;
            }

            // Oric .TAP 9-byte header:
            // hdr[0]: 0x00
            // hdr[1]: 0x00
            // hdr[2]: Program type (0x00 = BASIC, 0x80 = Machine Code)
            // hdr[3]: Auto-run flag (0xC7 = Auto-run, 0x00 = No)
            // hdr[4..5]: End address (MSB, LSB)
            // hdr[6..7]: Start address (MSB, LSB)
            // hdr[8]: Unused / flag
            const prog_type = bytes[pos + 2];
            const auto_run = bytes[pos + 3];
            const end_addr = (@as(u16, bytes[pos + 4]) << 8) | @as(u16, bytes[pos + 5]);
            const start_addr = (@as(u16, bytes[pos + 6]) << 8) | @as(u16, bytes[pos + 7]);
            pos += 9;

            const name_start = pos;
            while (pos < bytes.len and bytes[pos] != 0) {
                pos += 1;
            }
            const name = bytes[name_start..pos];
            if (pos < bytes.len and bytes[pos] == 0) {
                pos += 1;
            }

            if (end_addr < start_addr) {
                continue;
            }

            const data_len = @as(usize, end_addr - start_addr + 1);
            if (pos + data_len > bytes.len) {
                const available = bytes.len - pos;
                const data = bytes[pos .. pos + available];
                try self.blocks.append(self.allocator, .{
                    .prog_type = prog_type,
                    .auto_run = auto_run,
                    .start_addr = start_addr,
                    .end_addr = end_addr,
                    .name = name,
                    .data = data,
                });
                break;
            }

            const data = bytes[pos .. pos + data_len];
            pos += data_len;

            try self.blocks.append(self.allocator, .{
                .prog_type = prog_type,
                .auto_run = auto_run,
                .start_addr = start_addr,
                .end_addr = end_addr,
                .name = name,
                .data = data,
            });
        }

        if (self.blocks.items.len == 0) {
            return error.NoValidTapBlocks;
        }
    }

    pub const InjectResult = struct {
        start_addr: u16,
        auto_run: bool,
        is_mc: bool,
    };

    /// Fast-inject the first block into RAM and update Oric variables
    pub fn fast_inject(self: *Tape, ram: []u8) !InjectResult {
        if (self.blocks.items.len == 0) {
            return error.NoTapeBlocks;
        }

        const first = self.blocks.items[0];
        const b_start = @as(usize, first.start_addr);
        const auto_run = first.auto_run == 0xC7;
        const is_mc = (first.prog_type & 0x80) != 0;

        for (first.data, 0..) |b, i| {
            const addr = b_start + i;
            if (addr < ram.len) {
                ram[addr] = b;
            }
        }

        // If BASIC program (type 0x00), update BASIC pointers
        const end = @as(usize, first.end_addr);
        if (!is_mc and end < ram.len) {
            const next_free = @as(u16, @truncate(end + 1));
            // 0x9A/0x9B: TXTTAB (Start of BASIC program, must stay $0501)
            ram[0x9A] = 0x01;
            ram[0x9B] = 0x05;

            // 0x9C/0x9D: VARTAB (Start of variables / End of BASIC program text)
            ram[0x9C] = @as(u8, @truncate(next_free & 0xFF));
            ram[0x9D] = @as(u8, @truncate((next_free >> 8) & 0xFF));

            // 0x9E/0x9F: ARYTAB (Start of array variables)
            ram[0x9E] = @as(u8, @truncate(next_free & 0xFF));
            ram[0x9F] = @as(u8, @truncate((next_free >> 8) & 0xFF));

            // 0xA0/0xA1: STREND (End of arrays)
            ram[0xA0] = @as(u8, @truncate(next_free & 0xFF));
            ram[0xA1] = @as(u8, @truncate((next_free >> 8) & 0xFF));
        }

        // Advance raw_pos past Block 0 so subsequent CLOAD loads Block 1
        if (self.blocks.items.len > 1) {
            var pos: usize = 0;
            while (pos < self.raw_bytes.len) {
                if (self.raw_bytes[pos] == 0x24 and pos >= 1 and self.raw_bytes[pos - 1] == 0x16) {
                    pos += 1;
                    pos += 9;
                    while (pos < self.raw_bytes.len and self.raw_bytes[pos] != 0) {
                        pos += 1;
                    }
                    if (pos < self.raw_bytes.len and self.raw_bytes[pos] == 0) {
                        pos += 1;
                    }
                    pos += first.data.len;
                    break;
                }
                pos += 1;
            }
            self.raw_pos = pos;
        } else {
            self.raw_pos = self.raw_bytes.len;
        }

        return .{
            .start_addr = first.start_addr,
            .auto_run = auto_run,
            .is_mc = is_mc,
        };
    }
};
