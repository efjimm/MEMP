const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fetch-send",
        .root_source_file = b.path("fetch-send.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
}
