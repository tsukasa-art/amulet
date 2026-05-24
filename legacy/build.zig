const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols from release binaries") orelse false;

    const version = b.option([]const u8, "version", "Version string embedded in `amulet version`") orelse "0.0.0-dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "amulet",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_mod.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "amulet",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/probe_id.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const probe_exe = b.addExecutable(.{
        .name = "probe_id",
        .root_module = probe_mod,
    });
    b.installArtifact(probe_exe);

    const probe_run_cmd = b.addRunArtifact(probe_exe);
    probe_run_cmd.step.dependOn(b.getInstallStep());
    const probe_step = b.step("probe", "Run hardware-ID probe");
    probe_step.dependOn(&probe_run_cmd.step);

    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_test_mod.addOptions("build_options", build_options);
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_test_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const probe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/probe_id.zig"),
        .target = target,
        .optimize = optimize,
    });
    const probe_unit_tests = b.addTest(.{
        .root_module = probe_test_mod,
    });
    const run_probe_unit_tests = b.addRunArtifact(probe_unit_tests);

    const crypto_test_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crypto_unit_tests = b.addTest(.{
        .root_module = crypto_test_mod,
    });
    const run_crypto_unit_tests = b.addRunArtifact(crypto_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_probe_unit_tests.step);
    test_step.dependOn(&run_crypto_unit_tests.step);
}
