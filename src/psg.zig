const std = @import("std");

pub const AY_DAC_VOL: [16]i16 = [_]i16{
    0, 220, 315, 450, 640, 910, 1300, 1850,
    2600, 3700, 5200, 7400, 10500, 15000, 21500, 30000,
};

pub const Ay38912 = struct {
    regs: [16]u8 = [_]u8{0} ** 16,
    selected_reg: u8 = 0,

    // Tone generators (Channels A, B, C)
    tone_period: [3]u32 = [_]u32{0} ** 3,
    tone_counter: [3]u32 = [_]u32{0} ** 3,
    tone_output: [3]bool = [_]bool{true} ** 3,

    // Noise generator (17-bit LFSR)
    noise_period: u32 = 0,
    noise_counter: u32 = 0,
    noise_lfsr: u32 = 1,
    noise_output: bool = true,

    // Envelope generator
    env_period: u32 = 0,
    env_counter: u32 = 0,
    env_step: u8 = 0,
    env_volume: u8 = 0,
    env_shape: u8 = 0,
    env_holding: bool = false,

    // Audio sampling
    sample_rate: u32 = 44100,
    sample_accumulator: u32 = 0,
    sample_clock_step: u32 = (1_000_000 << 12) / 44100,
    audio_buffer: [8192]i16 = [_]i16{0} ** 8192,
    audio_len: usize = 0,

    pub fn init(sample_rate: u32) Ay38912 {
        var psg = Ay38912{
            .sample_rate = sample_rate,
            .sample_clock_step = (1_000_000 << 12) / sample_rate,
        };
        psg.reset();
        return psg;
    }

    pub fn reset(self: *Ay38912) void {
        @memset(&self.regs, 0);
        self.regs[7] = 0xFF; // All channels disabled by default
        self.regs[14] = 0xFF; // Keyboard columns default to all high (inactive)
        self.selected_reg = 0;

        self.noise_lfsr = 1;
        self.noise_period = 0;
        self.noise_counter = 0;
        self.noise_output = true;

        self.env_period = 0;
        self.env_counter = 0;
        self.env_step = 0;
        self.env_volume = 0;
        self.env_shape = 0;
        self.env_holding = false;

        for (0..3) |i| {
            self.tone_period[i] = 0;
            self.tone_counter[i] = 0;
            self.tone_output[i] = true;
        }

        self.audio_len = 0;
    }

    pub fn read_reg(self: *const Ay38912, reg: u8) u8 {
        if (reg < 16) {
            return self.regs[reg];
        } else {
            return 0xFF;
        }
    }

    pub fn write_reg(self: *Ay38912, reg: u8, val: u8) void {
        const r: usize = reg & 0x0F;
        self.regs[r] = val;

        switch (r) {
            0, 1 => {
                self.tone_period[0] = @as(u32, self.regs[0]) | (@as(u32, self.regs[1] & 0x0F) << 8);
            },
            2, 3 => {
                self.tone_period[1] = @as(u32, self.regs[2]) | (@as(u32, self.regs[3] & 0x0F) << 8);
            },
            4, 5 => {
                self.tone_period[2] = @as(u32, self.regs[4]) | (@as(u32, self.regs[5] & 0x0F) << 8);
            },
            6 => {
                self.noise_period = @as(u32, self.regs[6] & 0x1F);
            },
            11, 12 => {
                self.env_period = @as(u32, self.regs[11]) | (@as(u32, self.regs[12]) << 8);
            },
            13 => {
                self.env_shape = val & 0x0F;
                self.env_step = 0;
                self.env_holding = false;
            },
            else => {},
        }
    }

    /// Advance envelope generator state
    fn advance_envelope(self: *Ay38912) void {
        if (self.env_holding) {
            return;
        }

        var attack = (self.env_shape & 0x04) != 0;
        self.env_volume = if (attack) self.env_step else 15 - self.env_step;

        self.env_step = self.env_step +% 1;
        if (self.env_step > 15) {
            const cont = (self.env_shape & 0x08) != 0;
            if (!cont) {
                self.env_volume = 0;
                self.env_holding = true;
            } else {
                const alt = (self.env_shape & 0x02) != 0;
                const hold = (self.env_shape & 0x01) != 0;
                if (hold) {
                    if (alt) {
                        attack = !attack;
                    }
                    self.env_volume = if (attack) 15 else 0;
                    self.env_holding = true;
                } else {
                    if (alt) {
                        self.env_shape ^= 0x04;
                    }
                    self.env_step = 0;
                }
            }
        }
    }

    /// Step PSG by a given number of 1MHz CPU cycles
    pub fn step(self: *Ay38912, cycles: u32) void {
        var c: u32 = 0;
        while (c < cycles) : (c += 1) {
            // Tone counters (clocked at 1 MHz / 16)
            for (0..3) |ch| {
                const period = self.tone_period[ch];
                if (period > 0) {
                    self.tone_counter[ch] += 1;
                    if (self.tone_counter[ch] >= (period * 16)) {
                        self.tone_counter[ch] = 0;
                        self.tone_output[ch] = !self.tone_output[ch];
                    }
                } else {
                    self.tone_output[ch] = true;
                }
            }

            // Noise counter (clocked at 1 MHz / 16)
            const n_period: u32 = if (self.noise_period == 0) 1 else self.noise_period;
            self.noise_counter += 1;
            if (self.noise_counter >= (n_period * 16)) {
                self.noise_counter = 0;
                // 17-bit LFSR pseudo-random bit generator
                const bit0 = self.noise_lfsr & 1;
                const bit3 = (self.noise_lfsr >> 3) & 1;
                self.noise_lfsr = (self.noise_lfsr >> 1) | ((bit0 ^ bit3) << 16);
                self.noise_output = (self.noise_lfsr & 1) != 0;
            }

            // Envelope counter (clocked at 1 MHz / 256)
            const e_period: u32 = if (self.env_period == 0) 1 else self.env_period;
            self.env_counter += 1;
            if (self.env_counter >= (e_period * 16)) {
                self.env_counter = 0;
                self.advance_envelope();
            }

            // Audio sample generation check
            self.sample_accumulator += 1 << 12;
            if (self.sample_accumulator >= self.sample_clock_step) {
                self.sample_accumulator -= self.sample_clock_step;
                const sample = self.generate_sample();
                if (self.audio_len < self.audio_buffer.len) {
                    self.audio_buffer[self.audio_len] = sample;
                    self.audio_len += 1;
                }
            }
        }
    }

    /// Calculate instantaneous mixed audio sample (-32768..32767)
    pub fn generate_sample(self: *const Ay38912) i16 {
        const mixer = self.regs[7];
        var mixed: i32 = 0;

        for (0..3) |ch| {
            const ch_shift: u3 = @truncate(ch);
            const tone_disabled = (mixer & (@as(u8, 1) << ch_shift)) != 0;
            const noise_shift: u3 = @truncate(ch + 3);
            const noise_disabled = (mixer & (@as(u8, 1) << noise_shift)) != 0;

            const tone_bit = tone_disabled or self.tone_output[ch];
            const noise_bit = noise_disabled or self.noise_output;

            if (tone_bit and noise_bit) {
                const amp_reg = self.regs[8 + ch];
                const vol_idx: usize = if ((amp_reg & 0x10) != 0)
                    self.env_volume
                else
                    amp_reg & 0x0F;
                mixed += AY_DAC_VOL[@min(vol_idx, 15)];
            }
        }

        const output = std.math.clamp(@divTrunc(mixed, 3), -32768, 32767);
        return @as(i16, @intCast(output));
    }
};
