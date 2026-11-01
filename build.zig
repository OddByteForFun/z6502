const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module racine de la bibliothèque z6502
    const mod = b.addModule("z6502", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    mod.linkSystemLibrary("SDL2", .{});

    // Exécutable principal de l'émulateur
    const exe = b.addExecutable(.{
        .name = "z6502",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "z6502", .module = mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("SDL2", .{});

    b.installArtifact(exe);

    // Commande "zig build run"
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Exécuter l'émulateur Oric Atmos");
    run_step.dependOn(&run_cmd.step);

    // Commande "zig build test"
    const exe_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Exécuter tous les tests unitaires");
    test_step.dependOn(&run_tests.step);
}
