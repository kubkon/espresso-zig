const std = @import("std");

pub fn build(b: *std.Build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const libespresso = b.dependency("libespresso", .{
        .target = target,
        .optimize = mode,
    });

    const lib = b.addStaticLibrary(.{
        .name = "espresso-zig",
        .target = target,
        .optimize = mode,
    });
    lib.linkLibrary(libespresso.artifact("espresso"));
    lib.linkLibC();
    lib.install();

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    main_tests.linkLibrary(libespresso.artifact("espresso"));
    main_tests.linkLibC();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
