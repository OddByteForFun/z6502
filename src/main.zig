const std = @import("std");
const sdl = @import("sdl.zig");
const oric = @import("oric.zig");
const bus_mod = @import("bus.zig");
const video_mod = @import("video.zig");
const keyboard_mod = @import("keyboard.zig");

const FILE = anyopaque;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fclose(stream: *FILE) c_int;

const Config = struct {
    model: bus_mod.OricModel = .atmos,
    rom_path: ?[]const u8 = null,
    tap_path: ?[]const u8 = null,
    scale: u32 = 3,
    warp: bool = false,
    mute: bool = false,
};

fn printHelp() void {
    std.debug.print(
        \\=====================================================================
        \\  Émulateur Oric 1 / Atmos (MOS 6502) en Zig 0.16
        \\=====================================================================
        \\Usage:
        \\  z6502 [options]
        \\
        \\Options:
        \\  -m, --model <atmos|oric1>  Modèle à émuler (défaut: atmos)
        \\  -r, --rom <fichier>        Fichier ROM 16 Ko personnalisé (optionnel)
        \\  -t, --tap <fichier>        Cassette .TAP à charger au démarrage
        \\  -s, --scale <1..6>         Facteur d'échelle de la fenêtre vidéo (défaut: 3)
        \\  -w, --warp                 Mode vitesse maximale (sans limitation 50Hz)
        \\  -u, --mute                 Désactiver le son
        \\  -h, --help                 Afficher cette aide
        \\
        \\Raccourcis clavier :
        \\  F1          : Aide & état du microprocesseur et vidéo
        \\  Ctrl+F3/F12 : Reset machine
        \\  F4          : Basculer mode Warp (vitesse maximale)
        \\  F5          : Basculer entre Oric Atmos et Oric 1
        \\  F6          : Basculer disposition clavier (AZERTY / QWERTY)
        \\  Glisser-déposer un fichier .TAP sur la fenêtre pour charger une cassette
        \\  Disposition clavier par défaut : AZERTY
        \\=====================================================================
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    var config = Config{};

    var args_iter = init.args.iterate();
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            if (args_iter.next()) |m| {
                if (std.ascii.eqlIgnoreCase(m, "oric1") or std.ascii.eqlIgnoreCase(m, "oric")) {
                    config.model = .oric1;
                } else {
                    config.model = .atmos;
                }
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rom")) {
            config.rom_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tap")) {
            config.tap_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--scale")) {
            if (args_iter.next()) |s| {
                const parsed = std.fmt.parseInt(u32, s, 10) catch 3;
                config.scale = std.math.clamp(parsed, 1, 6);
            }
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warp")) {
            config.warp = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--mute")) {
            config.mute = true;
        }
    }

    var custom_rom: ?[]u8 = null;
    defer if (custom_rom) |r| allocator.free(r);

    if (config.rom_path) |path| {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (fopen(path_z.ptr, "rb")) |f| {
            defer _ = fclose(f);
            _ = fseek(f, 0, 2);
            const len: usize = @intCast(ftell(f));
            _ = fseek(f, 0, 0);
            if (len != 16384) {
                std.debug.print("Attention: Taille ROM {} octets (attendue: 16384 octets)\n", .{len});
            }
            const buf = try allocator.alloc(u8, len);
            _ = fread(buf.ptr, 1, len, f);
            custom_rom = buf;
        } else {
            std.debug.print("Erreur: Impossible d'ouvrir la ROM personnalisée: {s}\n", .{path});
        }
    }

    std.debug.print("=====================================================\n", .{});
    std.debug.print("  Émulateur Oric 1 / Atmos (MOS 6502) en Zig 0.16\n", .{});
    std.debug.print("  Modèle actif : {s}\n", .{if (config.model == .atmos) "Oric Atmos" else "Oric 1"});
    std.debug.print("=====================================================\n", .{});
    std.debug.print("Raccourcis :\n", .{});
    std.debug.print("  F1          : Aide & état\n", .{});
    std.debug.print("  Ctrl+F3/F12 : Reset machine\n", .{});
    std.debug.print("  F4          : Basculer mode Warp (vitesse max)\n", .{});
    std.debug.print("  F5          : Basculer entre Oric Atmos et Oric 1\n", .{});
    std.debug.print("  F6          : Basculer disposition clavier (AZERTY / QWERTY)\n", .{});
    std.debug.print("  Glisser-déposer un fichier .TAP sur la fenêtre pour charger une cassette\n", .{});
    std.debug.print("  Disposition clavier : AZERTY par défaut (F6 pour basculer)\n", .{});
    std.debug.print("=====================================================\n", .{});

    var machine = oric.Oric.init(allocator, config.model, custom_rom);
    defer machine.deinit();

    if (config.warp) {
        machine.warp_mode = true;
    }

    // Auto-load TAP file if provided
    if (config.tap_path) |tap_path| {
        // Fast-forward initial boot sequence so the machine is initialized and RAM test is complete
        var f: usize = 0;
        while (f < 180) : (f += 1) {
            machine.step_frame();
        }
        if (machine.load_tape_file(tap_path, true)) |msg| {
            std.debug.print("[Cassette] {s}\n", .{msg});
            allocator.free(msg);
        } else |err| {
            std.debug.print("[Erreur Cassette] {any}\n", .{err});
        }
    }

    // Initialize SDL2
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_TIMER | sdl.SDL_INIT_EVENTS) != 0) {
        std.debug.print("Erreur initialisation SDL: {s}\n", .{sdl.SDL_GetError()});
        return;
    }
    defer sdl.SDL_Quit();

    const scale = config.scale;
    const win_w: c_int = @intCast(video_mod.SCREEN_WIDTH * scale);
    const win_h: c_int = @intCast(video_mod.SCREEN_HEIGHT * scale);

    const title_z: [:0]const u8 = switch (config.model) {
        .atmos => "Oric Atmos Emulator (MOS 6502) - BASIC 1.1",
        .oric1 => "Oric-1 Emulator (MOS 6502) - BASIC 1.0",
    };

    const window = sdl.SDL_CreateWindow(
        title_z.ptr,
        sdl.SDL_WINDOWPOS_CENTERED,
        sdl.SDL_WINDOWPOS_CENTERED,
        win_w,
        win_h,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.debug.print("Erreur création fenêtre: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse {
        std.debug.print("Erreur création moteur de rendu: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl.SDL_PIXELFORMAT_ARGB8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        @intCast(video_mod.SCREEN_WIDTH),
        @intCast(video_mod.SCREEN_HEIGHT),
    ) orelse {
        std.debug.print("Erreur création texture: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyTexture(texture);

    // Audio setup
    const desired = sdl.SDL_AudioSpec{
        .freq = 44100,
        .format = sdl.AUDIO_S16SYS,
        .channels = 1,
        .silence = 0,
        .samples = 1024,
    };
    const audio_dev = if (!config.mute) sdl.SDL_OpenAudioDevice(null, 0, &desired, null, 0) else 0;
    defer if (audio_dev != 0) sdl.SDL_CloseAudioDevice(audio_dev);

    if (audio_dev != 0) {
        sdl.SDL_PauseAudioDevice(audio_dev, 0);
    } else if (!config.mute) {
        std.debug.print("[Audio] Avertissement: Impossible d'ouvrir le périphérique audio SDL: {s}\n", .{sdl.SDL_GetError()});
    }

    var event: sdl.SDL_Event = undefined;
    var running = true;
    var last_fps_time = sdl.SDL_GetTicks();
    var frame_count: u32 = 0;

    while (running) {
        const frame_start = sdl.SDL_GetTicks();

        // Poll events
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl.SDL_QUIT => {
                    running = false;
                },

                sdl.SDL_KEYDOWN => {
                    const sym = event.key.keysym.sym;
                    const mod = event.key.keysym.mod;

                    switch (sym) {
                        0x4000003A => { // F1
                            std.debug.print("--- État Oric ---\n", .{});
                            std.debug.print("Modèle : {s}\n", .{if (machine.bus.model == .atmos) "Atmos" else "Oric 1"});
                            std.debug.print(
                                "PC: ${X:0>4}  A: ${X:0>2}  X: ${X:0>2}  Y: ${X:0>2}  SP: ${X:0>2}  Flags: ${X:0>2}\n",
                                .{ machine.cpu.pc, machine.cpu.a, machine.cpu.x, machine.cpu.y, machine.cpu.sp, machine.cpu.status },
                            );
                            std.debug.print("Mode vidéo : {s}\n", .{if (machine.bus.video.hires_mode) "HIRES" else "TEXT"});
                        },

                        0x40000045 => { // F12
                            std.debug.print("[Oric] Reset machine...\n", .{});
                            machine.reset();
                        },

                        0x4000003C => { // F3
                            if ((mod & (sdl.KMOD_LCTRL | sdl.KMOD_RCTRL)) != 0) {
                                std.debug.print("[Oric] Reset machine...\n", .{});
                                machine.reset();
                            } else {
                                std.debug.print("[Oric] Touche F3 reçue. Pour réinitialiser la machine, utilisez Ctrl+F3 ou F12.\n", .{});
                            }
                        },

                        0x4000003D => { // F4
                            machine.warp_mode = !machine.warp_mode;
                            std.debug.print("[Oric] Mode Warp : {s}\n", .{if (machine.warp_mode) "Activé" else "Désactivé"});
                        },

                        0x4000003E => { // F5
                            const new_model: bus_mod.OricModel = if (machine.bus.model == .atmos) .oric1 else .atmos;
                            std.debug.print("[Oric] Basculement modèle vers {s}\n", .{if (new_model == .atmos) "Atmos" else "Oric 1"});
                            machine.switch_model(new_model);
                        },

                        0x4000003F => { // F6
                            const new_layout: keyboard_mod.KeyboardLayout = if (machine.bus.keyboard.layout == .azerty) .qwerty else .azerty;
                            machine.bus.keyboard.layout = new_layout;
                            std.debug.print("[Clavier] Disposition active : {s}\n", .{if (new_layout == .azerty) "AZERTY" else "QWERTY"});
                        },

                        else => {
                            machine.bus.keyboard.handle_key(sym, mod, true);
                        },
                    }
                },

                sdl.SDL_KEYUP => {
                    machine.bus.keyboard.handle_key(event.key.keysym.sym, event.key.keysym.mod, false);
                },

                sdl.SDL_DROPFILE => {
                    if (event.drop.file) |fpath| {
                        const span = std.mem.span(fpath);
                        std.debug.print("[Glisser-déposer] Chargement du fichier : {s}\n", .{span});
                        if (machine.load_tape_file(span, true)) |msg| {
                            std.debug.print("[Cassette] {s}\n", .{msg});
                            allocator.free(msg);
                        } else |err| {
                            std.debug.print("[Erreur Cassette] {any}\n", .{err});
                        }
                        sdl.SDL_free(fpath);
                    }
                },

                else => {},
            }
        }

        // Run one 50Hz frame of emulation
        machine.step_frame();

        // Queue audio samples to sound device
        if (audio_dev != 0) {
            if (machine.bus.ay.audio_len > 0) {
                if (sdl.SDL_GetQueuedAudioSize(audio_dev) < 16384) {
                    _ = sdl.SDL_QueueAudio(
                        audio_dev,
                        machine.bus.ay.audio_buffer[0..machine.bus.ay.audio_len].ptr,
                        @intCast(machine.bus.ay.audio_len * @sizeOf(i16)),
                    );
                }
            }
        }
        machine.bus.ay.audio_len = 0;

        // Update video texture
        _ = sdl.SDL_UpdateTexture(
            texture,
            null,
            machine.bus.video.framebuffer[0..].ptr,
            @intCast(video_mod.SCREEN_WIDTH * @sizeOf(u32)),
        );
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);

        frame_count += 1;
        const now = sdl.SDL_GetTicks();
        if (now - last_fps_time >= 1000) {
            const fps = frame_count;
            frame_count = 0;
            last_fps_time = now;

            var title_buf: [256:0]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "{s} - {d} FPS [{s}]{s} [{s}]",
                .{
                    if (machine.bus.model == .atmos) "Oric Atmos (BASIC 1.1)" else "Oric-1 (BASIC 1.0)",
                    fps,
                    if (machine.bus.video.hires_mode) "HIRES" else "TEXT",
                    if (machine.warp_mode) " [WARP]" else "",
                    if (machine.bus.keyboard.layout == .azerty) "AZERTY" else "QWERTY",
                },
            ) catch null;

            if (title) |t| {
                sdl.SDL_SetWindowTitle(window, t.ptr);
            }
        }

        // Frame rate limiter (50 FPS, PAL standard: 20 ms per frame)
        if (!machine.warp_mode) {
            const elapsed = sdl.SDL_GetTicks() - frame_start;
            if (elapsed < 20) {
                sdl.SDL_Delay(20 - elapsed);
            }
        }
    }
}
