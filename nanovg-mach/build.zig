const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const nanovg = b.createModule(.{
        .root_source_file = .{ .path = "../src/nanovg.zig" },
    });
    const nanovg_mod_dep = std.Build.Module.Import{ .name = "nanovg", .module = nanovg };

    const demo = b.createModule(.{
        .root_source_file = .{ .path = "../examples/demo.zig" },
        .imports = &.{nanovg_mod_dep},
    });

    const perf = b.createModule(.{
        .root_source_file = .{ .path = "../examples/perf.zig" },
        .imports = &.{nanovg_mod_dep},
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

    const gpu_module = nanovg_demo.core.compile.root_module.import_table.get("mach-core").?.import_table.get("mach-gpu").?;
    nanovg.addImport("gpu", gpu_module);

    try nanovg_demo.link();
    nanovg_demo.compile.addIncludePath(.{ .path = "../src" });
    nanovg_demo.compile.addCSourceFiles(.{
        .files = &.{ "../src/fontstash.c", "../src/stb_image.c" },
        .flags = &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" },
    });
    nanovg_demo.compile.linkLibC();

    nanovg_demo.run.step.dependOn(&nanovg_demo.install.step);

    const nanostep = b.step("run", "Run nanovg-demo");
    nanostep.dependOn(&nanovg_demo.run.step);
}
