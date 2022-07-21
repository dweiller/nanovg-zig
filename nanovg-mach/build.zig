const std = @import("std");
const mach = @import("mach/build.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const packages = struct {
        const nanovg = std.build.Pkg{
            .name = "nanovg",
            .source = .{ .path = "../src/nanovg.zig" },
            .dependencies = &.{
                @import("mach/gpu/build.zig").pkg,
            },
        };
    };

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const nanovg_demo = mach.App.init(b, .{
        .name = "nanovg-demo",
        .src = "main.zig",
        .target = target,
        .deps = &.{
            packages.nanovg,
            std.build.Pkg{
                .name = "demo",
                .source = .{ .path = "../examples/demo.zig" },
                .dependencies = &.{
                    packages.nanovg,
                },
            },
            std.build.Pkg{
                .name = "perf",
                .source = .{ .path = "../examples/perf.zig" },
                .dependencies = &.{
                    packages.nanovg,
                },
            },
        },
    });
    nanovg_demo.setBuildMode(mode);
    nanovg_demo.link(.{});
    nanovg_demo.step.addIncludePath("../src");
    nanovg_demo.step.addCSourceFile("../src/fontstash.c", &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" });
    nanovg_demo.step.addCSourceFile("../src/stb_image.c", &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" });
    nanovg_demo.step.linkLibC();
    nanovg_demo.install();

    const nanostep = b.step("run", "Run nanovg-demo");
    nanostep.dependOn(&nanovg_demo.run().step);
}
