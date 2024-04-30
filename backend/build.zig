const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_native = b.option(bool, "native", "Use native codegen backend") orelse false;

    const exe = b.addExecutable(.{
        .name = "backend",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
        .use_llvm = !use_native,
        .use_lld = !use_native,
    });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));

    const mqtt_dep = b.dependency("mqtt", .{});
    const mqtt = compileMqtt(b, mqtt_dep, target, optimize, use_native);

    exe.root_module.linkLibrary(mqtt);
    exe.root_module.addIncludePath(mqtt_dep.path("include"));
    exe.linkLibC();

    b.installArtifact(exe);

    const step = b.step("run", "Run the program");
    const run_step = b.addRunArtifact(exe);
    step.dependOn(&run_step.step);
}

fn compileMqtt(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native: bool,
) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "mqtt",
        .target = target,
        .optimize = optimize,
        .use_llvm = !native,
        .use_lld = !native,
    });

    lib.addCSourceFile(.{ .file = dep.path("src/mqtt.c") });
    lib.addCSourceFile(.{ .file = dep.path("src/mqtt_pal.c") });
    lib.linkLibC();
    lib.addIncludePath(dep.path("include"));

    return lib;
}
