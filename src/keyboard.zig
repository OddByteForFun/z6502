const std = @import("std");
const sdl = @import("sdl.zig");

pub const KeyboardLayout = enum {
    azerty,
    qwerty,
};

pub const KeyCoord = struct {
    row: usize,
    col: usize,
    shift: bool,
};

pub const PressedKey = struct {
    sym: i32,
    row: usize,
    col: usize,
    synth_shift: bool,
    supp_shift: bool,
};

pub const Keyboard = struct {
    /// 8 rows, each row has an 8-bit mask of columns (1 = pressed, 0 = released)
    matrix: [8]u8 = [_]u8{0} ** 8,

    /// Auto-typing circular queue for commands
    typein_buffer: [512]u8 = [_]u8{0} ** 512,
    typein_head: usize = 0,
    typein_tail: usize = 0,
    typein_timer: u32 = 0,
    typein_active_char: ?KeyCoord = null,

    /// Host keyboard layout (Azerty by default, toggleable to Qwerty)
    layout: KeyboardLayout = .azerty,

    /// Physical shift state from host PC
    real_lshift: bool = false,
    real_rshift: bool = false,

    /// Counter of active keys requiring synthetic Shift on Oric (e.g. ", #, !, etc.)
    synthetic_shift_count: u32 = 0,

    /// Counter of active keys that should suppress Shift on Oric (e.g. digits 0..9 on AZERTY)
    suppress_shift_count: u32 = 0,

    /// Active keys currently pressed
    pressed_keys: [64]PressedKey = [_]PressedKey{.{ .sym = 0, .row = 0, .col = 0, .synth_shift = false, .supp_shift = false }} ** 64,
    pressed_count: usize = 0,

    pub fn init() Keyboard {
        return .{};
    }

    pub fn reset(self: *Keyboard) void {
        @memset(&self.matrix, 0);
        self.typein_head = 0;
        self.typein_tail = 0;
        self.typein_timer = 0;
        self.typein_active_char = null;
        self.real_lshift = false;
        self.real_rshift = false;
        self.synthetic_shift_count = 0;
        self.suppress_shift_count = 0;
        self.pressed_count = 0;
    }

    pub fn set_key(self: *Keyboard, row: usize, col: usize, pressed: bool) void {
        if (row < 8 and col < 8) {
            const shift: u3 = @truncate(col);
            if (pressed) {
                self.matrix[row] |= (@as(u8, 1) << shift);
            } else {
                self.matrix[row] &= ~(@as(u8, 1) << shift);
            }
        }
    }

    /// Reconcile Oric Shift states based on physical modifiers, synthetic symbols,
    /// shift suppression (for AZERTY numbers), and auto-typein.
    pub fn update_shift(self: *Keyboard) void {
        const typein_shift = if (self.typein_active_char) |c| c.shift else false;
        const should_lshift = typein_shift or
            (((self.real_lshift or self.synthetic_shift_count > 0) and self.suppress_shift_count == 0));

        if (should_lshift) {
            self.matrix[4] |= (1 << 4); // Left Shift: Row 4, Col 4
        } else {
            self.matrix[4] &= ~@as(u8, 1 << 4);
        }

        const should_rshift = self.real_rshift and self.suppress_shift_count == 0;
        if (should_rshift) {
            self.matrix[7] |= (1 << 4); // Right Shift: Row 7, Col 4
        } else {
            self.matrix[7] &= ~@as(u8, 1 << 4);
        }
    }

    /// Read PB3 state given row (0..7) and column mask from AY-3-8912 Port A.
    /// Returns 0x08 if pressed (sensed low in hardware, converted to mask),
    /// or 0x00 if not pressed.
    pub fn read_bit(self: *const Keyboard, row: u8, ay_port_a: u8) u8 {
        const r: usize = row & 0x07;
        const scanned_cols: u8 = ~ay_port_a;
        if ((self.matrix[r] & scanned_cols) != 0) {
            return 0x08; // Key pressed -> PB3 is 0
        } else {
            return 0x00; // No key pressed -> PB3 is 1
        }
    }

    /// Queue a string to be automatically typed into the Oric (e.g. CLOAD"" or RUN)
    pub fn queue_string(self: *Keyboard, text: []const u8) void {
        for (text) |ch| {
            const next = (self.typein_tail + 1) % self.typein_buffer.len;
            if (next != self.typein_head) {
                self.typein_buffer[self.typein_tail] = ch;
                self.typein_tail = next;
            }
        }
    }

    /// Step the auto-typein mechanism (called once per frame, ~50Hz)
    pub fn step_typein(self: *Keyboard) void {
        if (self.typein_timer > 0) {
            self.typein_timer -= 1;
            return;
        }

        if (self.typein_active_char) |c| {
            // Release the current key
            self.set_key(c.row, c.col, false);
            if (c.shift) {
                self.set_key(4, 4, false); // Left Shift
            }
            self.typein_active_char = null;
            self.typein_timer = 3; // Pause 3 frames (~60ms) between keystrokes
            self.update_shift();
            return;
        }

        if (self.typein_head != self.typein_tail) {
            const ch = self.typein_buffer[self.typein_head];
            self.typein_head = (self.typein_head + 1) % self.typein_buffer.len;
            if (char_to_matrix(ch)) |coord| {
                if (coord.shift) {
                    self.set_key(4, 4, true); // Left Shift
                }
                self.set_key(coord.row, coord.col, true);
                self.typein_active_char = coord;
                self.typein_timer = 4; // Hold key for 4 frames (~80ms)
                self.update_shift();
            }
        }
    }

    /// Convert ASCII character to Oric Atmos / Oric-1 matrix coordinates
    pub fn char_to_matrix(ch: u8) ?KeyCoord {
        return switch (ch) {
            // Control
            0x08, 0x7F => .{ .row = 5, .col = 5, .shift = false }, // Backspace / Del
            '\t' => .{ .row = 4, .col = 7, .shift = false },       // Tab
            '\r', '\n' => .{ .row = 7, .col = 5, .shift = false }, // Return
            0x1B => .{ .row = 1, .col = 5, .shift = false },       // Escape
            ' ' => .{ .row = 4, .col = 0, .shift = false },        // Space

            // Shifted symbols
            '!' => .{ .row = 0, .col = 5, .shift = true },
            '"' => .{ .row = 3, .col = 7, .shift = true },
            '#' => .{ .row = 0, .col = 7, .shift = true },
            '$' => .{ .row = 2, .col = 3, .shift = true },
            '%' => .{ .row = 0, .col = 2, .shift = true },
            '&' => .{ .row = 0, .col = 0, .shift = true },
            '\'' => .{ .row = 3, .col = 7, .shift = false },
            '(' => .{ .row = 3, .col = 1, .shift = true },
            ')' => .{ .row = 7, .col = 2, .shift = true },
            '*' => .{ .row = 7, .col = 0, .shift = true },
            '+' => .{ .row = 7, .col = 7, .shift = true },
            ',' => .{ .row = 4, .col = 1, .shift = false },
            '-' => .{ .row = 3, .col = 3, .shift = false },
            '.' => .{ .row = 4, .col = 2, .shift = false },
            '/' => .{ .row = 7, .col = 3, .shift = false },

            // Digits 0..9
            '0' => .{ .row = 7, .col = 2, .shift = false },
            '1' => .{ .row = 0, .col = 5, .shift = false },
            '2' => .{ .row = 2, .col = 6, .shift = false },
            '3' => .{ .row = 0, .col = 7, .shift = false },
            '4' => .{ .row = 2, .col = 3, .shift = false },
            '5' => .{ .row = 0, .col = 2, .shift = false },
            '6' => .{ .row = 2, .col = 1, .shift = false },
            '7' => .{ .row = 0, .col = 0, .shift = false },
            '8' => .{ .row = 7, .col = 0, .shift = false },
            '9' => .{ .row = 3, .col = 1, .shift = false },

            ':' => .{ .row = 3, .col = 2, .shift = true },
            ';' => .{ .row = 3, .col = 2, .shift = false },
            '<' => .{ .row = 4, .col = 1, .shift = true },
            '=' => .{ .row = 7, .col = 7, .shift = false },
            '>' => .{ .row = 4, .col = 2, .shift = true },
            '?' => .{ .row = 7, .col = 3, .shift = true },
            '@' => .{ .row = 2, .col = 6, .shift = true },

            // Letters A..Z
            'A', 'a' => .{ .row = 6, .col = 5, .shift = false },
            'B', 'b' => .{ .row = 2, .col = 2, .shift = false },
            'C', 'c' => .{ .row = 2, .col = 7, .shift = false },
            'D', 'd' => .{ .row = 1, .col = 7, .shift = false },
            'E', 'e' => .{ .row = 6, .col = 3, .shift = false },
            'F', 'f' => .{ .row = 1, .col = 3, .shift = false },
            'G', 'g' => .{ .row = 6, .col = 2, .shift = false },
            'H', 'h' => .{ .row = 6, .col = 1, .shift = false },
            'I', 'i' => .{ .row = 5, .col = 1, .shift = false },
            'J', 'j' => .{ .row = 1, .col = 0, .shift = false },
            'K', 'k' => .{ .row = 3, .col = 0, .shift = false },
            'L', 'l' => .{ .row = 7, .col = 1, .shift = false },
            'M', 'm' => .{ .row = 2, .col = 0, .shift = false },
            'N', 'n' => .{ .row = 0, .col = 1, .shift = false },
            'O', 'o' => .{ .row = 5, .col = 2, .shift = false },
            'P', 'p' => .{ .row = 5, .col = 3, .shift = false },
            'Q', 'q' => .{ .row = 1, .col = 6, .shift = false },
            'R', 'r' => .{ .row = 1, .col = 2, .shift = false },
            'S', 's' => .{ .row = 6, .col = 6, .shift = false },
            'T', 't' => .{ .row = 1, .col = 1, .shift = false },
            'U', 'u' => .{ .row = 5, .col = 0, .shift = false },
            'V', 'v' => .{ .row = 0, .col = 3, .shift = false },
            'W', 'w' => .{ .row = 6, .col = 7, .shift = false },
            'X', 'x' => .{ .row = 0, .col = 6, .shift = false },
            'Y', 'y' => .{ .row = 6, .col = 0, .shift = false },
            'Z', 'z' => .{ .row = 2, .col = 5, .shift = false },

            '[' => .{ .row = 5, .col = 7, .shift = false },
            '\\' => .{ .row = 3, .col = 6, .shift = false },
            ']' => .{ .row = 5, .col = 6, .shift = false },
            '^' => .{ .row = 2, .col = 1, .shift = true },
            '_' => .{ .row = 3, .col = 3, .shift = true },
            '{' => .{ .row = 5, .col = 7, .shift = true },
            '|' => .{ .row = 3, .col = 6, .shift = true },
            '}' => .{ .row = 5, .col = 6, .shift = true },

            else => null,
        };
    }

    const MappingResult = struct {
        row: usize,
        col: usize,
        synth_shift: bool,
        supp_shift: bool,
    };

    pub fn handle_key(self: *Keyboard, sym: i32, keymod: u16, pressed: bool) void {
        const is_shift = (keymod & (sdl.KMOD_LSHIFT | sdl.KMOD_RSHIFT)) != 0;
        const is_altgr = (keymod & (sdl.KMOD_MODE | sdl.KMOD_RALT)) != 0 or
            ((keymod & sdl.KMOD_LCTRL) != 0 and (keymod & sdl.KMOD_RALT) != 0);

        // Modifiers handled specially
        if (sym == 0x400000E1) { // SDLK_LSHIFT
            self.real_lshift = pressed;
            self.update_shift();
            return;
        }
        if (sym == 0x400000E5) { // SDLK_RSHIFT
            self.real_rshift = pressed;
            self.update_shift();
            return;
        }

        // On key release: reliably release all entries associated with this keycode
        if (!pressed) {
            var i: usize = 0;
            while (i < self.pressed_count) {
                if (self.pressed_keys[i].sym == sym) {
                    const pk = self.pressed_keys[i];
                    self.set_key(pk.row, pk.col, false);
                    if (pk.synth_shift and self.synthetic_shift_count > 0) {
                        self.synthetic_shift_count -= 1;
                    }
                    if (pk.supp_shift and self.suppress_shift_count > 0) {
                        self.suppress_shift_count -= 1;
                    }

                    // Remove item by sliding
                    var j = i;
                    while (j + 1 < self.pressed_count) : (j += 1) {
                        self.pressed_keys[j] = self.pressed_keys[j + 1];
                    }
                    self.pressed_count -= 1;
                } else {
                    i += 1;
                }
            }
            self.update_shift();
            return;
        }

        // Ignore duplicate KeyDown events while the key is already held
        for (self.pressed_keys[0..self.pressed_count]) |pk| {
            if (pk.sym == sym) return;
        }

        const layout_mapping: ?MappingResult = switch (self.layout) {
            .azerty => switch (sym) {
                // Key 1: unshifted '&' (sym '&' or '1' unshifted), Shift '1'
                '&', '1' => if (is_altgr)
                    null
                else if (is_shift)
                    .{ .row = 0, .col = 5, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 0, .col = 5, .synth_shift = false, .supp_shift = false },

                // Key 2: unshifted 'é' (0xE9) or '2', Shift '2'
                0xE9, '2' => if (is_altgr)
                    .{ .row = 2, .col = 1, .synth_shift = true, .supp_shift = false } // AltGr '~' -> Oric '^'
                else if (is_shift)
                    .{ .row = 2, .col = 6, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 2, .col = 6, .synth_shift = false, .supp_shift = false },

                // Key 3: unshifted '"', Shift '3', AltGr '#'
                '3' => if (is_altgr)
                    .{ .row = 0, .col = 7, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 0, .col = 7, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 7, .synth_shift = true, .supp_shift = false },

                // Key 4: unshifted '\'', Shift '4', AltGr '{'
                '4' => if (is_altgr)
                    .{ .row = 5, .col = 7, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 2, .col = 3, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 7, .synth_shift = false, .supp_shift = false },

                // Key 5: unshifted '(', Shift '5', AltGr '['
                '5' => if (is_altgr)
                    .{ .row = 5, .col = 7, .synth_shift = false, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 0, .col = 2, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 1, .synth_shift = true, .supp_shift = false },

                // Key 6: unshifted '-', Shift '6', AltGr '|'
                '6' => if (is_altgr)
                    .{ .row = 3, .col = 6, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 2, .col = 1, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 3, .synth_shift = false, .supp_shift = false },

                // Key 7: unshifted 'è' (0xE8) or '7', Shift '7'
                0xE8, '7' => if (is_altgr)
                    .{ .row = 3, .col = 7, .synth_shift = false, .supp_shift = false } // AltGr '`'
                else if (is_shift)
                    .{ .row = 0, .col = 0, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 0, .col = 0, .synth_shift = false, .supp_shift = false },

                // Key 8: unshifted '_', Shift '8', AltGr '\'
                '8' => if (is_altgr)
                    .{ .row = 3, .col = 6, .synth_shift = false, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 7, .col = 0, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 3, .synth_shift = true, .supp_shift = false },

                // Key 9: unshifted 'ç' (0xE7) or '9', Shift '9', AltGr '^'
                0xE7, '9' => if (is_altgr)
                    .{ .row = 2, .col = 1, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 3, .col = 1, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 3, .col = 1, .synth_shift = false, .supp_shift = false },

                // Key 0: unshifted 'à' (0xE0) or '0', Shift '0', AltGr '@'
                0xE0, '0' => if (is_altgr)
                    .{ .row = 2, .col = 6, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 7, .col = 2, .synth_shift = false, .supp_shift = true }
                else
                    .{ .row = 7, .col = 2, .synth_shift = false, .supp_shift = false },

                // Key ): unshifted ')', AltGr ']'
                ')' => if (is_altgr)
                    .{ .row = 5, .col = 6, .synth_shift = false, .supp_shift = false }
                else
                    .{ .row = 7, .col = 2, .synth_shift = true, .supp_shift = false },

                // Key =: unshifted '=', Shift '+', AltGr '}'
                '=' => if (is_altgr)
                    .{ .row = 5, .col = 6, .synth_shift = true, .supp_shift = false }
                else if (is_shift)
                    .{ .row = 7, .col = 7, .synth_shift = true, .supp_shift = false }
                else
                    .{ .row = 7, .col = 7, .synth_shift = false, .supp_shift = false },

                else => null,
            },

            .qwerty => switch (sym) {
                '1' => if (is_shift) .{ .row = 0, .col = 5, .synth_shift = true, .supp_shift = false } else .{ .row = 0, .col = 5, .synth_shift = false, .supp_shift = false },
                '2' => if (is_shift) .{ .row = 2, .col = 6, .synth_shift = true, .supp_shift = false } else .{ .row = 2, .col = 6, .synth_shift = false, .supp_shift = false },
                '3' => if (is_shift) .{ .row = 0, .col = 7, .synth_shift = true, .supp_shift = false } else .{ .row = 0, .col = 7, .synth_shift = false, .supp_shift = false },
                '4' => if (is_shift) .{ .row = 2, .col = 3, .synth_shift = true, .supp_shift = false } else .{ .row = 2, .col = 3, .synth_shift = false, .supp_shift = false },
                '5' => if (is_shift) .{ .row = 0, .col = 2, .synth_shift = true, .supp_shift = false } else .{ .row = 0, .col = 2, .synth_shift = false, .supp_shift = false },
                '6' => if (is_shift) .{ .row = 2, .col = 1, .synth_shift = true, .supp_shift = false } else .{ .row = 2, .col = 1, .synth_shift = false, .supp_shift = false },
                '7' => if (is_shift) .{ .row = 0, .col = 0, .synth_shift = true, .supp_shift = false } else .{ .row = 0, .col = 0, .synth_shift = false, .supp_shift = false },
                '8' => if (is_shift) .{ .row = 7, .col = 0, .synth_shift = true, .supp_shift = false } else .{ .row = 7, .col = 0, .synth_shift = false, .supp_shift = false },
                '9' => if (is_shift) .{ .row = 3, .col = 1, .synth_shift = true, .supp_shift = false } else .{ .row = 3, .col = 1, .synth_shift = false, .supp_shift = false },
                '0' => if (is_shift) .{ .row = 7, .col = 2, .synth_shift = true, .supp_shift = false } else .{ .row = 7, .col = 2, .synth_shift = false, .supp_shift = false },
                '\'' => if (is_shift) .{ .row = 3, .col = 7, .synth_shift = true, .supp_shift = false } else .{ .row = 3, .col = 7, .synth_shift = false, .supp_shift = false },
                else => null,
            },
        };

        const res: MappingResult = if (layout_mapping) |m|
            m
        else switch (sym) {
            // Keypad digits
            0x40000062 => .{ .row = 7, .col = 2, .synth_shift = false, .supp_shift = true }, // KP 0
            0x40000059 => .{ .row = 0, .col = 5, .synth_shift = false, .supp_shift = true }, // KP 1
            0x4000005A => .{ .row = 2, .col = 6, .synth_shift = false, .supp_shift = true }, // KP 2
            0x4000005B => .{ .row = 0, .col = 7, .synth_shift = false, .supp_shift = true }, // KP 3
            0x4000005C => .{ .row = 2, .col = 3, .synth_shift = false, .supp_shift = true }, // KP 4
            0x4000005D => .{ .row = 0, .col = 2, .synth_shift = false, .supp_shift = true }, // KP 5
            0x4000005E => .{ .row = 2, .col = 1, .synth_shift = false, .supp_shift = true }, // KP 6
            0x4000005F => .{ .row = 0, .col = 0, .synth_shift = false, .supp_shift = true }, // KP 7
            0x40000060 => .{ .row = 7, .col = 0, .synth_shift = false, .supp_shift = true }, // KP 8
            0x40000061 => .{ .row = 3, .col = 1, .synth_shift = false, .supp_shift = true }, // KP 9

            // Direct symbols
            '"' => .{ .row = 3, .col = 7, .synth_shift = true, .supp_shift = false },
            '#' => .{ .row = 0, .col = 7, .synth_shift = true, .supp_shift = false },
            '\'' => .{ .row = 3, .col = 7, .synth_shift = false, .supp_shift = false },
            '!' => .{ .row = 0, .col = 5, .synth_shift = true, .supp_shift = false },
            '@' => .{ .row = 2, .col = 6, .synth_shift = true, .supp_shift = false },
            '$' => .{ .row = 2, .col = 3, .synth_shift = true, .supp_shift = false },
            '%' => .{ .row = 0, .col = 2, .synth_shift = true, .supp_shift = false },
            '^' => .{ .row = 2, .col = 1, .synth_shift = true, .supp_shift = false },
            '&' => .{ .row = 0, .col = 0, .synth_shift = true, .supp_shift = false },
            '*' => .{ .row = 7, .col = 0, .synth_shift = true, .supp_shift = false },
            '(' => .{ .row = 3, .col = 1, .synth_shift = true, .supp_shift = false },
            ')' => .{ .row = 7, .col = 2, .synth_shift = true, .supp_shift = false },
            '_' => .{ .row = 3, .col = 3, .synth_shift = true, .supp_shift = false },
            '+' => .{ .row = 7, .col = 7, .synth_shift = true, .supp_shift = false },
            ':' => .{ .row = 3, .col = 2, .synth_shift = true, .supp_shift = false },
            '?' => .{ .row = 7, .col = 3, .synth_shift = true, .supp_shift = false },
            '>' => .{ .row = 4, .col = 2, .synth_shift = true, .supp_shift = false },
            '<' => .{ .row = 4, .col = 1, .synth_shift = true, .supp_shift = false },

            // Letters A..Z
            'a' => .{ .row = 6, .col = 5, .synth_shift = false, .supp_shift = false },
            'b' => .{ .row = 2, .col = 2, .synth_shift = false, .supp_shift = false },
            'c' => .{ .row = 2, .col = 7, .synth_shift = false, .supp_shift = false },
            'd' => .{ .row = 1, .col = 7, .synth_shift = false, .supp_shift = false },
            'e' => .{ .row = 6, .col = 3, .synth_shift = false, .supp_shift = false },
            'f' => .{ .row = 1, .col = 3, .synth_shift = false, .supp_shift = false },
            'g' => .{ .row = 6, .col = 2, .synth_shift = false, .supp_shift = false },
            'h' => .{ .row = 6, .col = 1, .synth_shift = false, .supp_shift = false },
            'i' => .{ .row = 5, .col = 1, .synth_shift = false, .supp_shift = false },
            'j' => .{ .row = 1, .col = 0, .synth_shift = false, .supp_shift = false },
            'k' => .{ .row = 3, .col = 0, .synth_shift = false, .supp_shift = false },
            'l' => .{ .row = 7, .col = 1, .synth_shift = false, .supp_shift = false },
            'm' => .{ .row = 2, .col = 0, .synth_shift = false, .supp_shift = false },
            'n' => .{ .row = 0, .col = 1, .synth_shift = false, .supp_shift = false },
            'o' => .{ .row = 5, .col = 2, .synth_shift = false, .supp_shift = false },
            'p' => .{ .row = 5, .col = 3, .synth_shift = false, .supp_shift = false },
            'q' => .{ .row = 1, .col = 6, .synth_shift = false, .supp_shift = false },
            'r' => .{ .row = 1, .col = 2, .synth_shift = false, .supp_shift = false },
            's' => .{ .row = 6, .col = 6, .synth_shift = false, .supp_shift = false },
            't' => .{ .row = 1, .col = 1, .synth_shift = false, .supp_shift = false },
            'u' => .{ .row = 5, .col = 0, .synth_shift = false, .supp_shift = false },
            'v' => .{ .row = 0, .col = 3, .synth_shift = false, .supp_shift = false },
            'w' => .{ .row = 6, .col = 7, .synth_shift = false, .supp_shift = false },
            'x' => .{ .row = 0, .col = 6, .synth_shift = false, .supp_shift = false },
            'y' => .{ .row = 6, .col = 0, .synth_shift = false, .supp_shift = false },
            'z' => .{ .row = 2, .col = 5, .synth_shift = false, .supp_shift = false },

            // Punctuation & controls
            ' ' => .{ .row = 4, .col = 0, .synth_shift = false, .supp_shift = false },
            '\r', 0x40000058 => .{ .row = 7, .col = 5, .synth_shift = false, .supp_shift = false }, // Return / KP Enter
            0x1B => .{ .row = 1, .col = 5, .synth_shift = false, .supp_shift = false }, // Escape
            0x08, 0x7F, 0x4000004C => .{ .row = 5, .col = 5, .synth_shift = false, .supp_shift = false }, // Backspace / Delete
            '\t' => .{ .row = 4, .col = 7, .synth_shift = false, .supp_shift = false }, // Tab
            '-', 0x40000056 => .{ .row = 3, .col = 3, .synth_shift = false, .supp_shift = false }, // Minus / KP Minus
            '=', 0x40000067 => .{ .row = 7, .col = 7, .synth_shift = false, .supp_shift = false }, // Equals / KP Equals
            '[' => .{ .row = 5, .col = 7, .synth_shift = false, .supp_shift = false },
            ']' => .{ .row = 5, .col = 6, .synth_shift = false, .supp_shift = false },
            ';' => .{ .row = 3, .col = 2, .synth_shift = false, .supp_shift = false },
            ',' => .{ .row = 4, .col = 1, .synth_shift = false, .supp_shift = false },
            '.', 0x40000063 => .{ .row = 4, .col = 2, .synth_shift = false, .supp_shift = false }, // Period / KP Period
            '/', 0x40000054 => .{ .row = 7, .col = 3, .synth_shift = false, .supp_shift = false }, // Slash / KP Divide
            '\\' => .{ .row = 3, .col = 6, .synth_shift = false, .supp_shift = false },

            // Other modifiers
            0x400000E0 => .{ .row = 2, .col = 4, .synth_shift = false, .supp_shift = false }, // LCtrl
            0x400000E4 => .{ .row = 5, .col = 4, .synth_shift = false, .supp_shift = false }, // RCtrl

            // Cursor arrows
            0x40000052 => .{ .row = 4, .col = 3, .synth_shift = false, .supp_shift = false }, // Up
            0x40000051 => .{ .row = 4, .col = 6, .synth_shift = false, .supp_shift = false }, // Down
            0x40000050 => .{ .row = 4, .col = 5, .synth_shift = false, .supp_shift = false }, // Left
            0x4000004F => .{ .row = 4, .col = 7, .synth_shift = false, .supp_shift = false }, // Right

            // Atmos Function key
            0x400000E2, 0x400000E6, 0x4000004A => .{ .row = 3, .col = 4, .synth_shift = false, .supp_shift = false }, // LAlt / RAlt / Home

            else => return,
        };

        if (res.synth_shift) {
            self.synthetic_shift_count += 1;
        }
        if (res.supp_shift) {
            self.suppress_shift_count += 1;
        }

        self.set_key(res.row, res.col, true);
        if (self.pressed_count < self.pressed_keys.len) {
            self.pressed_keys[self.pressed_count] = .{
                .sym = sym,
                .row = res.row,
                .col = res.col,
                .synth_shift = res.synth_shift,
                .supp_shift = res.supp_shift,
            };
            self.pressed_count += 1;
        }
        self.update_shift();
    }
};

test "azerty key 3 variations" {
    var kbd = Keyboard.init();
    kbd.layout = .azerty;

    // 1. Unshifted key 3: produces '"' (Quote key row 3 col 7 with Shift)
    kbd.handle_key('3', 0, true);
    try std.testing.expect((kbd.matrix[3] & (1 << 7)) != 0);
    try std.testing.expect((kbd.matrix[4] & (1 << 4)) != 0);
    kbd.handle_key('3', 0, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[3] & (1 << 7));
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));

    // 2. Shifted key 3: produces '3' (digit 3: row 0 col 7 without Shift)
    kbd.handle_key(0x400000E1, sdl.KMOD_LSHIFT, true);
    kbd.handle_key('3', sdl.KMOD_LSHIFT, true);
    try std.testing.expect((kbd.matrix[0] & (1 << 7)) != 0);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));
    kbd.handle_key('3', sdl.KMOD_LSHIFT, false);
    kbd.handle_key(0x400000E1, 0, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[0] & (1 << 7));
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));

    // 3. AltGr key 3: produces '#' (row 0 col 7 with Shift)
    kbd.handle_key('3', sdl.KMOD_MODE, true);
    try std.testing.expect((kbd.matrix[0] & (1 << 7)) != 0);
    try std.testing.expect((kbd.matrix[4] & (1 << 4)) != 0);
    kbd.handle_key('3', sdl.KMOD_MODE, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[0] & (1 << 7));
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));
}

test "azerty key 4 variations" {
    var kbd = Keyboard.init();
    kbd.layout = .azerty;

    // 1. Unshifted key 4: produces '\'' (Quote key row 3 col 7 WITHOUT Shift)
    kbd.handle_key('4', 0, true);
    try std.testing.expect((kbd.matrix[3] & (1 << 7)) != 0);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));
    kbd.handle_key('4', 0, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[3] & (1 << 7));

    // 2. Shifted key 4: produces '4' (row 2 col 3 without Shift)
    kbd.handle_key(0x400000E1, sdl.KMOD_LSHIFT, true);
    kbd.handle_key('4', sdl.KMOD_LSHIFT, true);
    try std.testing.expect((kbd.matrix[2] & (1 << 3)) != 0);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4));
    kbd.handle_key('4', sdl.KMOD_LSHIFT, false);
    kbd.handle_key(0x400000E1, 0, false);
}

test "azerty key 2 variations" {
    var kbd = Keyboard.init();
    kbd.layout = .azerty;

    // 1. Unshifted key 2 (0xE9 for 'é'): produces digit 2 (row 2 col 6 without Shift)
    kbd.handle_key(0xE9, 0, true);
    try std.testing.expect((kbd.matrix[2] & (1 << 6)) != 0);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4)); // Shift not pressed
    kbd.handle_key(0xE9, 0, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[2] & (1 << 6));

    // 2. Shifted key 2 ('2'): produces digit 2 with Shift suppressed on Oric
    kbd.handle_key(0x400000E1, sdl.KMOD_LSHIFT, true);
    kbd.handle_key('2', sdl.KMOD_LSHIFT, true);
    try std.testing.expect((kbd.matrix[2] & (1 << 6)) != 0);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[4] & (1 << 4)); // Shift suppressed!
    kbd.handle_key('2', sdl.KMOD_LSHIFT, false);
    kbd.handle_key(0x400000E1, 0, false);
    try std.testing.expectEqual(@as(u8, 0), kbd.matrix[2] & (1 << 6));
}
