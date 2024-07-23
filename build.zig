const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nanovg_mod = b.addModule("nanovg", .{
        .root_source_file = b.path("src/nanovg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanovg_mod.addIncludePath(b.path("src"));
    nanovg_mod.addIncludePath(b.path("lib/gl2/include"));
    nanovg_mod.addCSourceFile(.{ .file = b.path("src/fontstash.c"), .flags = &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" } });
    nanovg_mod.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" } });

    if (target.result.isWasm()) {
        _ = installDemo(b, target, optimize, "demo", "examples/example_wasm.zig", nanovg_mod);
    } else {
        const demo_glfw = installDemo(b, target, optimize, "demo_glfw", "examples/example_glfw.zig", nanovg_mod);
        demo_glfw.addIncludePath(b.path("examples"));
        demo_glfw.addCSourceFile(.{ .file = b.path("examples/stb_image_write.c"), .flags = &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" } });
        _ = installDemo(b, target, optimize, "demo_fbo", "examples/example_fbo.zig", nanovg_mod);
        _ = installDemo(b, target, optimize, "demo_clip", "examples/example_clip.zig", nanovg_mod);

        if (b.lazyDependency("mach", .{ .optimize = optimize, .target = target })) |mach_dep| {
            const nanovg_mach = b.createModule(.{
                .root_source_file = b.path("src/nanovg.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "mach", .module = mach_dep.module("mach") }},
            });
            nanovg_mach.addIncludePath(b.path("src"));
            nanovg_mach.addCSourceFile(.{ .file = b.path("src/fontstash.c"), .flags = &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" } });
            nanovg_mach.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" } });

            const mach_demo = try addMachDemo(
                b,
                target,
                optimize,
                "demo_mach",
                "examples/mach.zig",
                nanovg_mach,
                mach_dep,
            );
            mach_demo.run.step.dependOn(&mach_demo.install.step);

            const nanostep = b.step("run-mach", "Run Mach demo");
            nanostep.dependOn(&mach_demo.run.step);
        }
    }
}

fn installDemo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root_source_file: []const u8, nanovg_mod: *std.Build.Module) *std.Build.Step.Compile {
    const demo = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    demo.root_module.addImport("nanovg", nanovg_mod);

    if (target.result.isWasm()) {
        demo.rdynamic = true;
        demo.entry = .disabled;
    } else {
        demo.addIncludePath(b.path("lib/gl2/include"));
        demo.addCSourceFile(.{ .file = b.path("lib/gl2/src/glad.c"), .flags = &.{} });
        switch (target.result.os.tag) {
            .windows => {
                b.installBinFile("glfw3.dll", "glfw3.dll");
                demo.linkSystemLibrary("glfw3dll");
                demo.linkSystemLibrary("opengl32");
            },
            .macos => {
                demo.addIncludePath(b.path("/opt/homebrew/include"));
                demo.addLibraryPath(b.path("/opt/homebrew/lib"));
                demo.linkSystemLibrary("glfw");
                demo.linkFramework("OpenGL");
            },
            .linux => {
                demo.linkSystemLibrary("glfw3");
                demo.linkSystemLibrary("GL");
                demo.linkSystemLibrary("X11");
            },
            else => {
                std.log.warn("Unsupported target: {}", .{target});
                demo.linkSystemLibrary("glfw3");
                demo.linkSystemLibrary("GL");
            },
        }
    }
    b.installArtifact(demo);
    return demo;
}

fn addMachDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_file: []const u8,
    nanovg_mod: *std.Build.Module,
    mach_dep: *std.Build.Dependency,
) !mach.CoreApp {
    const mach_builder = mach_dep.builder;
    const demo = try mach.CoreApp.init(b, mach_builder, .{
        .name = name,
        .src = root_source_file,
        .target = target,
        .optimize = optimize,
        .deps = &.{
            .{ .name = "nanovg", .module = nanovg_mod },
        },
        .mach_mod = mach_dep.module("mach"),
    });

    demo.compile.linkLibC();

    return demo;
}
