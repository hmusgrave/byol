const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("byol", "src/byol.zig");
    lib.setBuildMode(mode);
    lib.use_stage1 = true; // TODO: zig#6025
    lib.install();

    const main_tests = b.addTest("src/byol.zig");
    main_tests.use_stage1 = true; // TODO: zig#6025
    main_tests.test_evented_io = true;
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
