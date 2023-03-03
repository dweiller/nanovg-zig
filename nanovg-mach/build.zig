const std = @import("std");
const mach = @import("mach/build.zig");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const nanovg = b.createModule(.{
        .source_file = .{ .path = "../src/nanovg.zig" },
        .dependencies = &.{},
    });
    const nanovg_mod_dep = std.Build.ModuleDependency{ .name = "nanovg", .module = nanovg };

    const demo = b.createModule(.{
        .source_file = .{ .path = "../examples/demo.zig" },
        .dependencies = &.{nanovg_mod_dep},
    });

    const perf = b.createModule(.{
        .source_file = .{ .path = "../examples/perf.zig" },
        .dependencies = &.{nanovg_mod_dep},
    });

    const nanovg_demo = try mach.App.init(b, .{
        .name = "nanovg-demo",
        .src = "main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &.{
            nanovg_mod_dep,
            .{ .name = "demo", .module = demo },
            .{ .name = "perf", .module = perf },
        },
    });
    try nanovg.dependencies.put("gpu", nanovg_demo.step.modules.get("gpu").?);
    try nanovg_demo.link(.{});
    nanovg_demo.step.addIncludePath("../src");
    nanovg_demo.step.addCSourceFile("../src/fontstash.c", &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" });
    nanovg_demo.step.addCSourceFile("../src/stb_image.c", &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" });
    nanovg_demo.step.linkLibC();
    nanovg_demo.install();

    const nanovg_demo_run = nanovg_demo.step.run();
    nanovg_demo_run.condition = .always;

    const nanostep = b.step("run", "Run nanovg-demo");
    nanostep.dependOn(&nanovg_demo_run.step);
}
