const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");

const nvg = @import("nanovg");
const Demo = @import("demo");
const PerfGraph = @import("perf");

pub const App = @This();

vg: nvg,
demo: Demo,
fps: PerfGraph,
blowup: bool,
timer: std.time.Timer,
clear_pipeline: gpu.RenderPipeline,
quad_vertex_buffer: gpu.Buffer,

pub fn init(app: *App, core: *mach.Core) !void {
    try core.setOptions(.{
        .title = "nanovg-mach",
        .width = 1000,
        .height = 1000,
        .vsync = .none,
    });
    app.vg = try nvg.wgpu.init(
        core.allocator,
        core.device,
        &core.swap_chain,
        core.swap_chain_format,
        .{ .antialias = true },
    );
    app.demo.load(app.vg);
    app.fps = PerfGraph.init(.fps, "Frame Time");
    app.blowup = false;
    app.timer = try std.time.Timer.start();

    const shader_module = core.device.createShaderModule(&.{
        .label = "shader module",
        .code = .{ .wgsl = @embedFile("full_screen.wgsl") },
    });
    defer shader_module.release();

    app.quad_vertex_buffer = core.device.createBuffer(&gpu.Buffer.Descriptor{
        .label = "quad vertex buffer",
        .usage = .{ .vertex = true, .copy_dst = true },
        .size = quad_vert_data.len * @sizeOf(f32),
    });
    core.device.getQueue().writeBuffer(app.quad_vertex_buffer, 0, f32, &quad_vert_data);

    app.clear_pipeline = core.device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vert",
            .buffers = &[_]gpu.VertexBufferLayout{
                .{
                    // vertex buffer
                    .array_stride = 2 * 4,
                    .step_mode = .vertex,
                    .attribute_count = vertex_buffer_attributes.len,
                    .attributes = &vertex_buffer_attributes,
                },
            },
        },
        .fragment = &gpu.FragmentState{
            .module = shader_module,
            .entry_point = "frag",
            .targets = &[_]gpu.ColorTargetState{
                .{
                    .format = core.swap_chain_format,
                },
            },
        },
    });
}

const vertex_buffer_attributes = [_]gpu.VertexAttribute{
    .{
        // vertex positions
        .shader_location = 0,
        .offset = 0,
        .format = .float32x2,
    },
};

const quad_vert_data = [_]f32{
    -1, -1,
    1,  -1,
    1,  1,
    -1, -1,
    1,  1,
    -1, 1,
};

pub fn deinit(app: *App, _: *mach.Core) void {
    app.demo.free(app.vg);
    app.vg.deinit();
}

pub fn update(app: *App, core: *mach.Core) !void {
    const back_buffer_view = core.swap_chain.?.getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .resolve_target = null,
        .clear_value = .{ .r = 0.3, .g = 0.3, .b = 0.32, .a = 1 },
        .load_op = .clear,
        .store_op = .store,
    };
    const render_pass_descriptor = gpu.RenderPassEncoder.Descriptor{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{
            color_attachment,
        },
    };

    while (core.pollEvent()) |event| switch (event) {
        .key_press => |ev| switch (ev.key) {
            .space => app.blowup = !app.blowup,
            else => {},
        },
        else => {},
    };

    const command_encoder = core.device.createCommandEncoder(null);
    {
        const pass_encoder = command_encoder.beginRenderPass(&render_pass_descriptor);
        pass_encoder.setPipeline(app.clear_pipeline);
        pass_encoder.setVertexBuffer(0, app.quad_vertex_buffer, 0, 12 * @sizeOf(f32));
        pass_encoder.draw(6, 1, 0, 0);
        pass_encoder.end();
        pass_encoder.release();
    }
    var command = command_encoder.finish(null);
    command_encoder.release();
    core.device.getQueue().submit(&.{command});
    command.release();

    app.fps.update(core.delta_time);
    const ns = app.timer.read();
    const t = @intToFloat(f32, ns) / std.time.ns_per_s;

    const window_size = core.getWindowSize();
    const fb_size = core.getFramebufferSize();
    const px_ratio = @intToFloat(f32, fb_size.width) / @intToFloat(f32, window_size.width);
    app.vg.beginFrame(@intToFloat(f32, window_size.width), @intToFloat(f32, window_size.height), px_ratio);

    const m_pos = core.internal.last_cursor_position;
    app.demo.draw(
        app.vg,
        @floatCast(f32, m_pos.x),
        @floatCast(f32, m_pos.y),
        @intToFloat(f32, window_size.width),
        @intToFloat(f32, window_size.height),
        t,
        app.blowup,
    );
    app.fps.draw(app.vg, 5, 5);

    app.vg.endFrame();

    core.swap_chain.?.present();
    back_buffer_view.release();
}
