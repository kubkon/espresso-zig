const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const espresso_c_dep = b.dependency("espresso", .{});

    const lib = b.addStaticLibrary("espresso-zig", "src/main.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.linkLibrary(espresso_c_dep.artifact("espresso"));
    lib.linkLibC();
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
