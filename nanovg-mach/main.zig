const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");

const nvg = @import("nanovg");
const Demo = @import("demo");
const PerfGraph = @import("perf");

pub const App = @This();

core: mach.Core,
vg: nvg,
demo: Demo,
fps: PerfGraph,
blowup: bool,
cursor_position: mach.Core.Position,
timer: mach.Timer,
total_time: f32,
clear_pipeline: *gpu.RenderPipeline,
quad_vertex_buffer: *gpu.Buffer,

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn init(app: *App) !void {
    const allocator = gpa.allocator();
    try app.core.init(allocator, .{
        .title = "nanovg-mach",
        .size = .{
            .width = 1000,
            .height = 1000,
        },
    });
    app.core.setVSync(.none);

    var device = app.core.device();
    const swap_chain_format = app.core.descriptor().format;
    app.vg = try nvg.wgpu.init(
        allocator,
        device,
        &app.core.internal.swap_chain,
        swap_chain_format,
        .{ .antialias = true },
    );
    app.demo.load(app.vg);
    app.fps = PerfGraph.init(.fps, "Frame Time");
    app.blowup = false;
    app.timer = try mach.Timer.start();
    app.total_time = 0;

    const shader_module = device.createShaderModule(&.{
        .label = "shader module",
        .next_in_chain = .{ .wgsl_descriptor = &.{ .code = @embedFile("full_screen.wgsl") } },
    });
    defer shader_module.release();

    app.quad_vertex_buffer = device.createBuffer(&gpu.Buffer.Descriptor{
        .label = "quad vertex buffer",
        .usage = .{ .vertex = true, .copy_dst = true },
        .size = quad_vert_data.len * @sizeOf(f32),
    });
    device.getQueue().writeBuffer(app.quad_vertex_buffer, 0, &quad_vert_data);

    app.clear_pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
        .label = "clear pipeline",
        .vertex = .{
            .module = shader_module,
            .entry_point = "vert",
            .buffers = &[1]gpu.VertexBufferLayout{
                .{
                    // vertex buffer
                    .array_stride = 2 * 4,
                    .step_mode = .vertex,
                    .attribute_count = vertex_buffer_attributes.len,
                    .attributes = &vertex_buffer_attributes,
                },
            },
            .buffer_count = 1,
        },
        .fragment = &gpu.FragmentState{
            .module = shader_module,
            .entry_point = "frag",
            .targets = &[1]gpu.ColorTargetState{
                .{
                    .format = swap_chain_format,
                },
            },
            .target_count = 1,
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

pub fn deinit(app: *App) void {
    app.demo.free(app.vg);
    app.vg.deinit();
    app.core.deinit();
}

pub fn update(app: *App) !bool {
    var events = app.core.pollEvents();
    while (events.next()) |event| switch (event) {
        .key_press => |ev| switch (ev.key) {
            .space => app.blowup = !app.blowup,
            else => {},
        },
        .mouse_motion => |m_ev| app.cursor_position = m_ev.pos,
        .close => return true,
        else => {},
    };

    const back_buffer_view = app.core.swapChain().getCurrentTextureView() orelse return error.NoBackBuffer;
    defer back_buffer_view.release();

    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .resolve_target = null,
        .clear_value = .{ .r = 0.3, .g = 0.3, .b = 0.32, .a = 1 },
        .load_op = .clear,
        .store_op = .store,
    };
    const render_pass_descriptor = gpu.RenderPassDescriptor{
        .label = "main render pass descriptor",
        .color_attachments = &[1]gpu.RenderPassColorAttachment{
            color_attachment,
        },
        .color_attachment_count = 1,
    };

    const device = app.core.device();
    const command_encoder = device.createCommandEncoder(null);
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
    device.getQueue().submit(&[1]*const gpu.CommandBuffer{command});
    command.release();

    const delta_time = app.timer.lap();
    app.total_time += delta_time;
    app.fps.update(delta_time);

    const window_size = app.core.size();
    const fb_size = app.core.framebufferSize();
    const px_ratio = @as(f32, @floatFromInt(fb_size.width)) / @as(f32, @floatFromInt(window_size.width));
    app.vg.beginFrame(@floatFromInt(window_size.width), @floatFromInt(window_size.height), px_ratio);

    const m_pos = app.cursor_position;
    app.demo.draw(
        app.vg,
        @floatCast(m_pos.x),
        @floatCast(m_pos.y),
        @floatFromInt(window_size.width),
        @floatFromInt(window_size.height),
        app.total_time,
        app.blowup,
    );
    app.fps.draw(app.vg, 5, 5);

    app.vg.endFrame();

    app.core.swapChain().present();
    return false;
}
