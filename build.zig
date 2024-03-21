const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nanovg_mod = b.addModule("nanovg", .{
        .root_source_file = .{ .path = "src/nanovg.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanovg_mod.addIncludePath(.{ .path = "src" });
    nanovg_mod.addIncludePath(.{ .path = "lib/gl2/include" });
    nanovg_mod.addCSourceFile(.{ .file = .{ .path = "src/fontstash.c" }, .flags = &.{ "-DFONS_NO_STDIO", "-fno-stack-protector" } });
    nanovg_mod.addCSourceFile(.{ .file = .{ .path = "src/stb_image.c" }, .flags = &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" } });

    if (target.result.isWasm()) {
        _ = installDemo(b, target, optimize, "demo", "examples/example_wasm.zig", nanovg_mod);
    } else {
        const demo_glfw = installDemo(b, target, optimize, "demo_glfw", "examples/example_glfw.zig", nanovg_mod);
        demo_glfw.addIncludePath(.{ .path = "examples" });
        demo_glfw.addCSourceFile(.{ .file = .{ .path = "examples/stb_image_write.c" }, .flags = &.{ "-DSTBI_NO_STDIO", "-fno-stack-protector" } });
        _ = installDemo(b, target, optimize, "demo_fbo", "examples/example_fbo.zig", nanovg_mod);
        _ = installDemo(b, target, optimize, "demo_clip", "examples/example_clip.zig", nanovg_mod);
    }
}

fn installDemo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root_source_file: []const u8, nanovg_mod: *std.Build.Module) *std.Build.Step.Compile {
    const demo = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = root_source_file },
        .target = target,
        .optimize = optimize,
    });
    demo.root_module.addImport("nanovg", nanovg_mod);

    if (target.result.isWasm()) {
        demo.rdynamic = true;
        demo.entry = .disabled;
    } else {
        demo.addIncludePath(.{ .path = "lib/gl2/include" });
        demo.addCSourceFile(.{ .file = .{ .path = "lib/gl2/src/glad.c" }, .flags = &.{} });
        switch (target.result.os.tag) {
            .windows => {
                b.installBinFile("glfw3.dll", "glfw3.dll");
                demo.linkSystemLibrary("glfw3dll");
                demo.linkSystemLibrary("opengl32");
            },
            .macos => {
                demo.addIncludePath(.{ .path = "/opt/homebrew/include" });
                demo.addLibraryPath(.{ .path = "/opt/homebrew/lib" });
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
