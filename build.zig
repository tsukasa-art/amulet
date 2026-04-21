const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // ReleaseSafe is the recommended mode. Use: zig build -Doptimize=ReleaseSafe
    // ReleaseFast is intentionally not recommended — safety checks must stay on.
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols from release binaries") orelse false;

    const version = b.option([]const u8, "version", "Version string embedded in `amulet version`") orelse "0.0.0-dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const lib = b.addStaticLibrary(.{
        .name = "amulet",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "amulet",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.strip = strip;
    exe.root_module.addOptions("build_options", build_options);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const probe_exe = b.addExecutable(.{
        .name = "probe_id",
        .root_source_file = b.path("src/probe_id.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_exe.root_module.strip = strip;
    b.installArtifact(probe_exe);

    const probe_run_cmd = b.addRunArtifact(probe_exe);
    probe_run_cmd.step.dependOn(b.getInstallStep());
    const probe_step = b.step("probe", "Run hardware-ID probe");
    probe_step.dependOn(&probe_run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addOptions("build_options", build_options);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const probe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/probe_id.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_probe_unit_tests = b.addRunArtifact(probe_unit_tests);

    const crypto_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_crypto_unit_tests = b.addRunArtifact(crypto_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_probe_unit_tests.step);
    test_step.dependOn(&run_crypto_unit_tests.step);
}
