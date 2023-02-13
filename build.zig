const std = @import("std");

pub fn build(b: *std.Build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    b.addModule(.{
        .name = "espresso",
        .source_file = .{ .path = "src/main.zig" },
    });

    const libespresso = b.dependency("libespresso", .{
        .target = target,
        .optimize = mode,
    });
    const libeqntott = b.dependency("libeqntott", .{
        .target = target,
        .optimize = mode,
    });

    const lib = b.addStaticLibrary(.{
        .name = "espresso-zig",
        .target = target,
        .optimize = mode,
    });
    lib.linkLibrary(libespresso.artifact("espresso"));
    lib.linkLibrary(libeqntott.artifact("eqntott-lib"));
    lib.linkLibC();
    lib.install();

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    main_tests.linkLibrary(libespresso.artifact("espresso"));
    main_tests.linkLibrary(libeqntott.artifact("eqntott-lib"));
    main_tests.linkLibC();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
