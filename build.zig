const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-yaml is vendored under vendor/zig-yaml. We build its library module
    // directly rather than using the package manager because the upstream
    // build.zig unconditionally imports a test file that does not compile on
    // Zig 0.16 (see vendor/zig-yaml/VENDOR.md).
    const yaml_mod = b.createModule(.{
        .root_source_file = b.path("vendor/zig-yaml/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "startpage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // zig build run -- <config.yaml> [more.yaml ...] [-o out.html]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run the startpage generator");
    run_step.dependOn(&run_cmd.step);

    // zig build example -> render workspaces to zig-out/startpage.html. Mirrors
    // the CLI's default input precedence: your real config/ if it has any config
    // files, otherwise the bundled examples/workspaces demo.
    const input_dir: []const u8 = if (hasYaml(b.graph.io, b.build_root.handle, "config")) "config" else "examples/workspaces";
    const example_cmd = b.addRunArtifact(exe);
    example_cmd.addDirectoryArg(b.path(input_dir));
    example_cmd.addArg("-o");
    const example_out = example_cmd.addOutputFileArg("startpage.html");
    const install_example = b.addInstallFileWithDir(example_out, .prefix, "startpage.html");
    const example_step = b.step("example", b.fmt("Generate zig-out/startpage.html from {s}", .{input_dir}));
    example_step.dependOn(&install_example.step);

    // zig build test -> run unit tests, then generate and open startpage.html
    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const opener = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "explorer",
        else => "xdg-open",
    };
    const open_cmd = b.addSystemCommand(&.{ opener, b.getInstallPath(.prefix, "startpage.html") });
    open_cmd.has_side_effects = true; // always open, even when the page is unchanged/cached
    open_cmd.step.dependOn(&install_example.step);

    const test_step = b.step("test", "Run unit tests, then build and open startpage.html");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&open_cmd.step);

    // zig build test-only -> run unit tests without generating/opening the page
    const test_only_step = b.step("test-only", "Run unit tests only (no browser)");
    test_only_step.dependOn(&run_unit_tests.step);
}

/// True if `sub` is a directory (relative to the build root) containing at least
/// one `*.yaml`/`*.yml` file — used to prefer config/ over the bundled examples.
fn hasYaml(io: std.Io, root: std.Io.Dir, sub: []const u8) bool {
    var dir = root.openDir(io, sub, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        if (std.mem.endsWith(u8, entry.name, ".yaml") or std.mem.endsWith(u8, entry.name, ".yml")) return true;
    }
    return false;
}
