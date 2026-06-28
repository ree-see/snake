const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize });

    const server = b.addExecutable(.{ .name = "http-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    b.installArtifact(server);

    const tui = b.addExecutable(.{
        .name = "snake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    tui.root_module.addImport("core", core_mod);

    b.installArtifact(tui);

    const wasm = b.addExecutable(.{
        .name = "snake-wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });

    wasm.root_module.addImport("core", core_mod);

    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    // `zig build server` -- launch http server
    const server_cmd = b.addRunArtifact(server);
    server_cmd.step.dependOn(b.getInstallStep());

    const server_step = b.step("server", "launch the http server");
    server_step.dependOn(&server_cmd.step);

    // `zig build run` -- launch the interactive TUI (ESC quits).
    const run_cmd = b.addRunArtifact(tui);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build wasm` -- builds wasm library
    const wasm_step = b.step("wasm", "Create wasm bin");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // `zig build test` -- run the `test {}` blocks in src/main.zig.
    const exe_tests = b.addTest(.{
        .root_module = tui.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_tests.step);
}
