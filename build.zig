const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize });

    const ws_mod = b.createModule(.{ .root_source_file = b.path("src/websocket.zig"), .target = target, .optimize = optimize });
    ws_mod.addImport("core", core_mod);

    const session_mod = b.createModule(.{ .root_source_file = b.path("src/session.zig"), .target = target, .optimize = optimize });
    session_mod.addImport("core", core_mod);
    session_mod.addImport("websocket", ws_mod);

    const server = b.addExecutable(.{ .name = "game-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    server.root_module.addImport("core", core_mod);
    server.root_module.addImport("websocket", ws_mod);
    server.root_module.addImport("session", session_mod);

    b.installArtifact(server);

    const classic = b.addExecutable(.{
        .name = "snake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    classic.root_module.addImport("core", core_mod);
    classic.is_linking_libc = true;

    b.installArtifact(classic);

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

    const server_step = b.step("server", "launch the server");
    server_step.dependOn(&server_cmd.step);

    // `zig build run` -- launch the interactive TUI (ESC quits).
    const run_cmd = b.addRunArtifact(classic);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("classic", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build wasm` -- builds wasm library
    const wasm_step = b.step("wasm", "Create wasm bin");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // `zig build test` -- run the `test {}` blocks in src/tui.zig.
    const exe_tests = b.addTest(.{
        .root_module = classic.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const session_tests = b.addTest(.{ .root_module = session_mod });
    const ws_tests = b.addTest(.{ .root_module = ws_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const run_session_tests = b.addRunArtifact(session_tests);
    const run_ws_tests = b.addRunArtifact(ws_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_session_tests.step);
    test_step.dependOn(&run_ws_tests.step);
}
