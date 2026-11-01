const std = @import("std");

pub const SDL_INIT_TIMER: u32 = 0x00000001;
pub const SDL_INIT_AUDIO: u32 = 0x00000010;
pub const SDL_INIT_VIDEO: u32 = 0x00000020;
pub const SDL_INIT_EVENTS: u32 = 0x00004000;

pub const SDL_WINDOW_SHOWN: u32 = 0x00000004;
pub const SDL_WINDOW_RESIZABLE: u32 = 0x00000020;
pub const SDL_WINDOWPOS_CENTERED: c_int = @bitCast(@as(u32, 0x2FFF0000));

pub const SDL_RENDERER_ACCELERATED: u32 = 0x00000002;
pub const SDL_RENDERER_PRESENTVSYNC: u32 = 0x00000004;

pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
pub const SDL_PIXELFORMAT_ARGB8888: u32 = 0x16362004;

pub const SDL_QUIT: u32 = 0x100;
pub const SDL_KEYDOWN: u32 = 0x300;
pub const SDL_KEYUP: u32 = 0x301;
pub const SDL_DROPFILE: u32 = 0x1000;

pub const AUDIO_S16SYS: u16 = 0x8010;

pub const KMOD_LSHIFT: u16 = 0x0001;
pub const KMOD_RSHIFT: u16 = 0x0002;
pub const KMOD_LCTRL: u16 = 0x0040;
pub const KMOD_RCTRL: u16 = 0x0080;
pub const KMOD_RALT: u16 = 0x0200;
pub const KMOD_MODE: u16 = 0x4000; // AltGr on Linux

pub const SDL_Keysym = extern struct {
    scancode: u32,
    sym: i32,
    mod: u16,
    unused: u32,
};

pub const SDL_KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    padding2: u16,
    keysym: SDL_Keysym,
};

pub const SDL_DropEvent = extern struct {
    type: u32,
    timestamp: u32,
    file: ?[*:0]u8,
    windowID: u32,
};

pub const SDL_Event = extern union {
    type: u32,
    key: SDL_KeyboardEvent,
    drop: SDL_DropEvent,
    padding: [56]u8,
};

pub const SDL_AudioSpec = extern struct {
    freq: c_int,
    format: u16,
    channels: u8,
    silence: u8,
    samples: u16,
    padding: u16 = 0,
    size: u32 = 0,
    callback: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) void = null,
    userdata: ?*anyopaque = null,
};

pub const SDL_Window = anyopaque;
pub const SDL_Renderer = anyopaque;
pub const SDL_Texture = anyopaque;
pub const SDL_Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub extern "c" fn SDL_Init(flags: u32) c_int;
pub extern "c" fn SDL_Quit() void;
pub extern "c" fn SDL_GetError() [*:0]const u8;

pub extern "c" fn SDL_CreateWindow(
    title: [*:0]const u8,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    flags: u32,
) ?*SDL_Window;
pub extern "c" fn SDL_DestroyWindow(window: *SDL_Window) void;
pub extern "c" fn SDL_SetWindowTitle(window: *SDL_Window, title: [*:0]const u8) void;

pub extern "c" fn SDL_CreateRenderer(window: *SDL_Window, index: c_int, flags: u32) ?*SDL_Renderer;
pub extern "c" fn SDL_DestroyRenderer(renderer: *SDL_Renderer) void;
pub extern "c" fn SDL_RenderClear(renderer: *SDL_Renderer) c_int;
pub extern "c" fn SDL_RenderCopy(
    renderer: *SDL_Renderer,
    texture: *SDL_Texture,
    srcrect: ?*const SDL_Rect,
    dstrect: ?*const SDL_Rect,
) c_int;
pub extern "c" fn SDL_RenderPresent(renderer: *SDL_Renderer) void;

pub extern "c" fn SDL_CreateTexture(
    renderer: *SDL_Renderer,
    format: u32,
    access: c_int,
    w: c_int,
    h: c_int,
) ?*SDL_Texture;
pub extern "c" fn SDL_DestroyTexture(texture: *SDL_Texture) void;
pub extern "c" fn SDL_LockTexture(
    texture: *SDL_Texture,
    rect: ?*const SDL_Rect,
    pixels: *?*anyopaque,
    pitch: *c_int,
) c_int;
pub extern "c" fn SDL_UnlockTexture(texture: *SDL_Texture) void;
pub extern "c" fn SDL_UpdateTexture(
    texture: *SDL_Texture,
    rect: ?*const SDL_Rect,
    pixels: *const anyopaque,
    pitch: c_int,
) c_int;

pub extern "c" fn SDL_PollEvent(event: *SDL_Event) c_int;

pub extern "c" fn SDL_OpenAudioDevice(
    device: ?[*:0]const u8,
    iscapture: c_int,
    desired: *const SDL_AudioSpec,
    obtained: ?*SDL_AudioSpec,
    allowed_changes: c_int,
) u32;
pub extern "c" fn SDL_CloseAudioDevice(dev: u32) void;
pub extern "c" fn SDL_PauseAudioDevice(dev: u32, pause_on: c_int) void;
pub extern "c" fn SDL_QueueAudio(dev: u32, data: *const anyopaque, len: u32) c_int;
pub extern "c" fn SDL_GetQueuedAudioSize(dev: u32) u32;
pub extern "c" fn SDL_ClearQueuedAudio(dev: u32) void;

pub extern "c" fn SDL_Delay(ms: u32) void;
pub extern "c" fn SDL_GetTicks() u32;
pub extern "c" fn SDL_GetPerformanceCounter() u64;
pub extern "c" fn SDL_GetPerformanceFrequency() u64;
pub extern "c" fn SDL_free(mem: ?*anyopaque) void;
