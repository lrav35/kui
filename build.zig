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

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path("src/main.zig");

    // Create librdkafka as a static library
    const rdkafka = b.addStaticLibrary(.{
        .name = "rdkafka",
        .target = target,
        .optimize = optimize,
    });

    // Add all necessary C source files
    const rdkafka_base_path = b.path("dependencies/librdkafka/src");
    const rdkafka_sources = [_][]const u8{
        "rdkafka.c",
        "rdkafka_broker.c",
        "rdkafka_msg.c",
        "rdkafka_topic.c",
    };

    const c_flags = [_][]const u8{
        "-fPIC",
        "-DLIBRDKAFKA_STATICLIB",
    };

    for (rdkafka_sources) |src| {
        const source_path = rdkafka_base_path.pathJoin(b.allocator, src) catch @panic("OOM");
        rdkafka.addCSourceFile(.{
            .file = source_path,
            .flags = &c_flags,
        });
    }

    rdkafka.linkLibC();
    rdkafka.addIncludePath(rdkafka_base_path);

    const kui = b.addExecutable(.{
        .name = "kui",
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const deps = .{
        .vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }),
    };

    kui.linkLibC();
    kui.linkLibrary(rdkafka);
    kui.addIncludePath(rdkafka_base_path);

    kui.root_module.addImport("vaxis", deps.vaxis.module("vaxis"));

    b.installArtifact(kui);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(kui);

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
}
