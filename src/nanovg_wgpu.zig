const std = @import("std");
const Allocator = std.mem.Allocator;

const gpu = @import("gpu");
const nvg = @import("nanovg.zig");
const internal = @import("internal.zig");

pub const Options = struct {
    // debug: bool = false,
};

const clear_value = gpu.Color{ .r = 1, .g = 0, .b = 1, .a = 1 };

const log = std.log.scoped(.NanoVGWebGPU);

pub fn init(
    allocator: Allocator,
    device: *gpu.Device,
    swap_chain: *const *gpu.SwapChain,
    swap_chain_format: gpu.Texture.Format,
    options: Options,
) !nvg {
    const webgpu_context = try WebGPUContext.init(
        allocator,
        device,
        swap_chain,
        swap_chain_format,
        options,
    );
    const params = internal.Params{
        .user_ptr = webgpu_context,
        .renderCreate = renderCreate,
        .renderCreateTexture = renderCreateTexture,
        .renderDeleteTexture = renderDeleteTexture,
        .renderUpdateTexture = renderUpdateTexture,
        .renderGetTextureSize = renderGetTextureSize,
        .renderViewport = renderViewport,
        .renderCancel = renderCancel,
        .renderFlush = renderFlush,
        .renderFill = renderFill,
        .renderStroke = renderStroke,
        .renderTriangles = renderTriangles,
        .renderDelete = renderDelete,
    };
    return nvg{
        .ctx = try internal.Context.init(allocator, params),
    };
}

const WebGPUContext = struct {
    allocator: Allocator,
    device: *gpu.Device,
    swap_chain: *const *gpu.SwapChain,
    swap_chain_format: gpu.Texture.Format,
    depth_stencil: ?*gpu.Texture = null,
    depth_stencil_view: ?*gpu.TextureView = null,
    options: Options,
    pass: Pass,
    view: [2]f32,
    textures: std.ArrayListUnmanaged(Texture) = .{},
    next_tex_id: i32 = 1,
    calls: std.ArrayListUnmanaged(Call) = .{},
    paths: std.ArrayListUnmanaged(Path) = .{},
    verts: std.ArrayListUnmanaged(internal.Vertex) = .{},
    uniforms: std.ArrayListUnmanaged(FragUniforms) = .{},

    fn init(
        allocator: Allocator,
        device: *gpu.Device,
        swap_chain: *const *gpu.SwapChain,
        swap_chain_format: gpu.Texture.Format,
        options: Options,
    ) !*WebGPUContext {
        const self = try allocator.create(WebGPUContext);
        self.* = WebGPUContext{
            .allocator = allocator,
            .device = device,
            .swap_chain = swap_chain,
            .swap_chain_format = swap_chain_format,
            .options = options,
            .pass = undefined,
            .view = .{ 0, 0 },
        };
        return self;
    }

    fn deinit(ctx: *WebGPUContext) void {
        ctx.pass.deinit();
        ctx.textures.deinit(ctx.allocator);
        ctx.calls.deinit(ctx.allocator);
        ctx.paths.deinit(ctx.allocator);
        ctx.verts.deinit(ctx.allocator);
        ctx.uniforms.deinit(ctx.allocator);

        if (ctx.depth_stencil_view) |view| {
            view.release();
        }
        if (ctx.depth_stencil) |tex| {
            tex.destroy();
            tex.release();
        }

        ctx.allocator.destroy(ctx);
    }

    fn castPtr(ptr: *anyopaque) *WebGPUContext {
        return @ptrCast(@alignCast(ptr));
    }

    // TODO: alloc/find texture
    fn allocTexture(ctx: *WebGPUContext) !*Texture {
        const tex = try ctx.textures.addOne(ctx.allocator);
        tex.id = ctx.next_tex_id;
        ctx.next_tex_id += 1;
        return tex;
    }

    fn getTexture(ctx: WebGPUContext, id: i32) ?*Texture {
        for (ctx.textures.items) |*texture| {
            if (texture.id == id) return texture;
        }
        return null;
    }

    fn removeTexture(ctx: *WebGPUContext, id: i32) ?Texture {
        for (ctx.textures.items, 0..) |*texture, i| {
            if (texture.id == id) return ctx.textures.swapRemove(i);
        }
        return null;
    }

    fn setUniforms(ctx: WebGPUContext, command_encoder: *gpu.CommandEncoder, uniform_offset: u32) void {
        const frag = ctx.uniforms.items[uniform_offset .. uniform_offset + 1];
        command_encoder.writeBuffer(ctx.pass.uniforms, 0, frag);
    }

    fn setTextures(ctx: WebGPUContext, pass_encoder: *gpu.RenderPassEncoder, call: Call) void {
        if (ctx.getTexture(call.image)) |tex| {
            pass_encoder.setBindGroup(1, tex.bind_group[0], null);
        } else {
            pass_encoder.setBindGroup(1, ctx.pass.fallback_texture_bind_group, null);
        }
        if (ctx.getTexture(call.colormap)) |tex| {
            pass_encoder.setBindGroup(2, tex.bind_group[1], null);
        } else {
            pass_encoder.setBindGroup(2, ctx.pass.fallback_texture_bind_group, null);
        }
    }

    fn startEncoding(
        ctx: WebGPUContext,
        command_encoder: *gpu.CommandEncoder,
        desc: gpu.RenderPassDescriptor,
    ) *gpu.RenderPassEncoder {
        const pass_encoder = command_encoder.beginRenderPass(&desc);
        pass_encoder.setVertexBuffer(0, ctx.pass.vert_buf, 0, ctx.pass.vert_size);
        pass_encoder.setBindGroup(0, ctx.pass.bind_group, null);
        return pass_encoder;
    }
};

const ShaderType = enum(u32) {
    fill_gradient,
    fill_image,
    simple,
    image,
};

const vert_attributes = [_]gpu.VertexAttribute{
    .{
        // pos
        .shader_location = 0,
        .offset = 0,
        .format = .float32x2,
    },
    .{
        // tex coord
        .shader_location = 1,
        .offset = 2 * @sizeOf(f32),
        .format = .float32x2,
    },
};

fn xformToMat3x4(m3: *[12]f32, t: *const [6]f32) void {
    m3[0] = t[0];
    m3[1] = t[1];
    m3[2] = 0;
    m3[3] = 0;
    m3[4] = t[2];
    m3[5] = t[3];
    m3[6] = 0;
    m3[7] = 0;
    m3[8] = t[4];
    m3[9] = t[5];
    m3[10] = 1;
    m3[11] = 0;
}

fn premulColor(c: nvg.Color) Color {
    return .{ .r = c.r * c.a, .g = c.g * c.a, .b = c.b * c.a, .a = c.a };
}

const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const FragUniforms = struct {
    scissor_mat: [12]f32,
    paint_mat: [12]f32,
    inner_color: Color,
    outer_color: Color,
    scissor_extent: [2]f32,
    scissor_scale: [2]f32,
    extent: [2]f32,
    radius: f32,
    feather: f32,
    tex_type: f32,
    shader_type: f32,

    fn fromPaint(frag: *FragUniforms, paint: *nvg.Paint, scissor: *internal.Scissor, ctx: *WebGPUContext) i32 {
        var invxform: [6]f32 = undefined;

        frag.* = std.mem.zeroes(FragUniforms);

        frag.inner_color = premulColor(paint.inner_color);
        frag.outer_color = premulColor(paint.outer_color);

        if (scissor.extent[0] < -0.5 or scissor.extent[1] < -0.5) {
            @memset(&frag.scissor_mat, 0);
            frag.scissor_extent[0] = 1;
            frag.scissor_extent[1] = 1;
            frag.scissor_scale[0] = 1;
            frag.scissor_scale[1] = 1;
        } else {
            _ = nvg.transformInverse(&invxform, &scissor.xform);
            xformToMat3x4(&frag.scissor_mat, &invxform);
            frag.scissor_extent[0] = scissor.extent[0];
            frag.scissor_extent[1] = scissor.extent[1];
            frag.scissor_scale[0] = @sqrt(scissor.xform[0] * scissor.xform[0] + scissor.xform[2] * scissor.xform[2]);
            frag.scissor_scale[1] = @sqrt(scissor.xform[1] * scissor.xform[1] + scissor.xform[3] * scissor.xform[3]);
        }

        @memcpy(&frag.extent, &paint.extent);

        if (paint.image.handle != 0) {
            const tex = ctx.getTexture(paint.image.handle) orelse return 0;
            if (tex.flags.flip_y) {
                var m1: [6]f32 = undefined;
                var m2: [6]f32 = undefined;
                nvg.transformTranslate(&m1, 0, frag.extent[1] * 0.5);
                nvg.transformMultiply(&m1, &paint.xform);
                nvg.transformScale(&m2, 1, -1);
                nvg.transformMultiply(&m2, &m1);
                nvg.transformTranslate(&m1, 0, -frag.extent[1] * 0.5);
                nvg.transformMultiply(&m1, &m2);
                _ = nvg.transformInverse(&invxform, &m1);
            } else {
                _ = nvg.transformInverse(&invxform, &paint.xform);
            }
            frag.shader_type = @floatFromInt(@intFromEnum(ShaderType.fill_image));

            if (tex.tex_type == .rgba) {
                frag.tex_type = if (tex.flags.premultiplied) 0 else 1;
            } else if (paint.colormap.handle == 0) {
                frag.tex_type = 2;
            } else {
                frag.tex_type = 3;
            }
        } else {
            frag.shader_type = @floatFromInt(@intFromEnum(ShaderType.fill_gradient));
            frag.radius = paint.radius;
            frag.feather = paint.feather;
            _ = nvg.transformInverse(&invxform, &paint.xform);
        }

        xformToMat3x4(&frag.paint_mat, &invxform);

        return 1;
    }
};

const Pass = struct {
    stroke: struct {
        stencil_base: *gpu.RenderPipeline,
        stencil_aa: *gpu.RenderPipeline,
        stencil_clear: *gpu.RenderPipeline,
        basic: *gpu.RenderPipeline,
    },
    fill: struct {
        stencil: *gpu.RenderPipeline,
        fill: *gpu.RenderPipeline,
    },
    convex: struct {
        fill: *gpu.RenderPipeline,
        fringe: *gpu.RenderPipeline,
    },
    tri: struct {
        pipeline: *gpu.RenderPipeline,
    },
    sampler: *gpu.Sampler,
    vert_buf: *gpu.Buffer,
    vert_size: usize,
    uniforms: *gpu.Buffer,
    bind_group: *gpu.BindGroup,
    view_buf: *gpu.Buffer,
    texture_layout: *gpu.BindGroupLayout,
    fallback_texture: *gpu.Texture,
    fallback_texture_bind_group: *gpu.BindGroup,

    fn init(pass: *Pass, device: *gpu.Device, swap_chain_format: gpu.Texture.Format) !void {
        const shader_module = device.createShaderModule(&gpu.ShaderModule.Descriptor{
            .label = "nanovg shader module",
            .next_in_chain = .{ .wgsl_descriptor = &.{ .code = @embedFile("nanovg.wgsl") } },
        });

        const blend = gpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
            },
        };

        pass.fallback_texture = device.createTexture(&gpu.Texture.Descriptor{
            .label = "nanovg fallback texture",
            .size = gpu.Extent3D{ .width = 1, .height = 1 },
            .format = .rgba8_unorm,
            .usage = .{
                .texture_binding = true,
                .copy_dst = true,
            },
        });

        const texture_layout = device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor{
            .label = "nanovg texture bind group layout",
            .entries = &[1]gpu.BindGroupLayout.Entry{
                gpu.BindGroupLayout.Entry.texture(0, .{ .fragment = true }, .float, .dimension_2d, false),
            },
            .entry_count = 1,
        });
        pass.texture_layout = texture_layout;

        pass.fallback_texture_bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor{
            .label = "nanovg fallback texture bind group",
            .layout = texture_layout,
            .entries = &[1]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.textureView(0, pass.fallback_texture.createView(&gpu.TextureView.Descriptor{
                    .label = "nanovg fallback texture view",
                    .dimension = .dimension_2d,
                })),
            },
            .entry_count = 1,
        });

        const bind_group_layout = device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor{ .label = "nanovg bind group 0 layout", .entries = &[3]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, false, 0),
            gpu.BindGroupLayout.Entry.buffer(1, .{ .fragment = true }, .uniform, false, 0),
            gpu.BindGroupLayout.Entry.sampler(2, .{ .fragment = true }, .filtering),
        }, .entry_count = 3 });
        defer bind_group_layout.release();

        const pipeline_layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor{
            .label = "nanovg pipeline layout",
            .bind_group_layouts = &[3]*gpu.BindGroupLayout{
                bind_group_layout,
                texture_layout,
                texture_layout,
            },
            .bind_group_layout_count = 3,
        });
        defer pipeline_layout.release();

        const buffer_layout = gpu.VertexBufferLayout{
            .array_stride = 4 * @sizeOf(f32),
            .attribute_count = vert_attributes.len,
            .attributes = &vert_attributes,
        };

        const vertex_state = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vert",
            .buffers = &[_]gpu.VertexBufferLayout{buffer_layout},
            .buffer_count = 1,
        };

        const color_target_write_all = gpu.ColorTargetState{
            .format = swap_chain_format,
            .blend = &blend,
        };

        const color_target_write_none = gpu.ColorTargetState{
            .format = swap_chain_format,
            .blend = &blend,
            .write_mask = .{ .red = false, .green = false, .blue = false, .alpha = false },
        };

        const fragment_state = gpu.FragmentState{
            .module = shader_module,
            .entry_point = "fragNoEdgeAA",
            .targets = &[1]gpu.ColorTargetState{color_target_write_all},
            .target_count = 1,
        };

        const fragment_state_no_write = gpu.FragmentState{
            .module = shader_module,
            .entry_point = "fragNoEdgeAA",
            .targets = &[1]gpu.ColorTargetState{color_target_write_none},
            .target_count = 1,
        };

        const depth_stencil_incr_clamp = gpu.DepthStencilState{
            .format = .stencil8,
            .stencil_front = .{
                .compare = .equal,
                .pass_op = .increment_clamp,
            },
            .stencil_back = .{
                .compare = .equal,
                .pass_op = .increment_clamp,
            },
            // .stencil_read_mask = 0xff, // TODO: check if this is needed, or the default value works
            // .stencil_write_mask = 0xff, // TODO: check if this is needed, or the default value works
        };

        const depth_stencil_equal_keep = gpu.DepthStencilState{
            .format = .stencil8,
            .stencil_front = .{
                .compare = .equal,
            },
            .stencil_back = .{
                .compare = .equal,
            },
            // .stencil_read_mask = 0xff, // TODO: check if this is needed, or the default value works
            // .stencil_write_mask = 0xff, // TODO: check if this is needed, or the default value works
        };

        const depth_stencil_always_zero = gpu.DepthStencilState{
            .format = .stencil8,
            .stencil_front = .{
                .pass_op = .zero,
            },
            .stencil_back = .{
                .pass_op = .zero,
            },
            // .stencil_read_mask = 0xff, // TODO: check if this is needed, or the default value works
            // .stencil_write_mask = 0xff, // TODO: check if this is needed, or the default value works
        };

        const depth_stencil_notequal_zero = gpu.DepthStencilState{
            .format = .stencil8,
            .stencil_front = .{
                .compare = .not_equal,
                .pass_op = .zero,
            },
            .stencil_back = .{
                .compare = .not_equal,
                .pass_op = .zero,
            },
            // .stencil_read_mask = 0xff, // TODO: check if this is needed, or the default value works
            // .stencil_write_mask = 0xff, // TODO: check if this is needed, or the default value works
        };

        pass.tri.pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "nanovg triangle pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .layout = pipeline_layout,
            .primitive = .{ .cull_mode = .back },
        });

        pass.convex.fill = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "nanovg convexfill fill pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .layout = pipeline_layout,
            .primitive = .{ .cull_mode = .back },
        });

        pass.convex.fringe = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "nanovg convexfill fringe pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .layout = pipeline_layout,
        });

        pass.fill.stencil = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "nanovg fill stencil pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state_no_write,
            .layout = pipeline_layout,
            .depth_stencil = &gpu.DepthStencilState{
                .format = .stencil8,
                .stencil_front = .{
                    .compare = .always,
                    .pass_op = .increment_wrap,
                },
                .stencil_back = .{
                    .compare = .always,
                    .pass_op = .decrement_wrap,
                },
                // .stencil_read_mask = 0xff, // TODO: check if this is needed, or the default value works
                // .stencil_write_mask = 0xff, // TODO: check if this is needed, or the default value works
            },
        });

        pass.fill.fill = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "nanovg fill fill pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .depth_stencil = &depth_stencil_notequal_zero,
            .layout = pipeline_layout,
        });

        pass.stroke.basic = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "strip pipeline",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .layout = pipeline_layout,
        });

        pass.stroke.stencil_base = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "stroke base",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .depth_stencil = &depth_stencil_incr_clamp,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .layout = pipeline_layout,
        });

        pass.stroke.stencil_aa = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "stroke aa",
            .vertex = vertex_state,
            .fragment = &fragment_state,
            .depth_stencil = &depth_stencil_equal_keep,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .layout = pipeline_layout,
        });

        pass.stroke.stencil_clear = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = "strok stencil clear",
            .vertex = vertex_state,
            .fragment = &fragment_state_no_write,
            .depth_stencil = &depth_stencil_always_zero,
            .primitive = .{ .topology = .triangle_strip, .cull_mode = .back },
            .layout = pipeline_layout,
        });

        const uniform_buffer_size = comptime std.mem.alignForward(usize, @sizeOf(FragUniforms), 16);
        const uniform_buffer = device.createBuffer(&gpu.Buffer.Descriptor{
            .label = "nanovg uniform buffer",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = uniform_buffer_size,
        });
        pass.uniforms = uniform_buffer;

        const vert_buffer = device.createBuffer(&gpu.Buffer.Descriptor{
            .label = "nanovg vertex buffer",
            .usage = .{
                .vertex = true,
                .copy_dst = true,
            },
            // TODO: better initial size
            .size = 0,
        });
        pass.vert_buf = vert_buffer;
        pass.vert_size = 0;

        // TODO: check sampler settings
        const sampler = device.createSampler(&gpu.Sampler.Descriptor{
            .label = "nanovg sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
        });
        pass.sampler = sampler;

        const view_buffer = device.createBuffer(&gpu.Buffer.Descriptor{
            .label = "nanovg view uniform buffer",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf([2]f32),
        });
        pass.view_buf = view_buffer;

        const bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor{
            .label = "nanovg bind group 0",
            .layout = bind_group_layout,
            .entries = &[3]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.buffer(0, view_buffer, 0, @sizeOf([2]f32)),
                gpu.BindGroup.Entry.buffer(1, uniform_buffer, 0, uniform_buffer_size),
                gpu.BindGroup.Entry.sampler(2, sampler),
            },
            .entry_count = 3,
        });
        pass.bind_group = bind_group;
    }

    fn deinit(self: *Pass) void {
        self.vert_buf.destroy();
        self.uniforms.destroy();
        self.view_buf.destroy();
        self.sampler.release();
        self.bind_group.release();
        self.texture_layout.release();
        self.fallback_texture.destroy();
        self.stroke.basic.release();
        self.stroke.stencil_aa.release();
        self.stroke.stencil_base.release();
        self.stroke.stencil_clear.release();
        self.fill.stencil.release();
        self.fill.fill.release();
        self.convex.fill.release();
        self.convex.fringe.release();
        self.tri.pipeline.release();
    }
};

const Texture = struct {
    id: i32,
    tex: *gpu.Texture,
    tex_type: internal.TextureType,
    flags: nvg.ImageFlags,
    bind_group: [2]*gpu.BindGroup,
    size: gpu.Extent3D,
    data_layout: gpu.Texture.DataLayout,
};

const Path = struct {
    fill_offset: u32,
    fill_count: u32,
    stroke_offset: u32,
    stroke_count: u32,
};

fn maxVertCount(paths: []const internal.Path) usize {
    var count: usize = 0;
    for (paths) |path| {
        count += 3 * path.fill.len;
        count += path.stroke.len;
    }
    return count;
}

const Call = struct {
    call_type: CallType,
    image: i32,
    colormap: i32,
    path_offset: u32,
    path_count: u32,
    triangle_offset: u32,
    triangle_count: u32,
    uniform_offset: u32,
    // blend: Blend,

    const CallType = enum {
        none,
        fill,
        convexfill,
        stroke,
        triangles,
    };

    fn fill(
        call: Call,
        ctx: *const WebGPUContext,
        command_encoder: *gpu.CommandEncoder,
        back_buffer_view: *gpu.TextureView,
    ) void {
        const paths = ctx.paths.items[call.path_offset..][0..call.path_count];
        {
            const desc = gpu.RenderPassDescriptor{
                .label = "fill render pass 1",
                .color_attachments = &[1]gpu.RenderPassColorAttachment{
                    .{
                        .view = back_buffer_view,
                        .load_op = .load,
                        .store_op = .store,
                        .clear_value = clear_value,
                    },
                },
                .color_attachment_count = 1,
                .depth_stencil_attachment = &gpu.RenderPassDepthStencilAttachment{
                    .view = ctx.depth_stencil_view.?,
                    .stencil_load_op = .load,
                    .stencil_store_op = .store,
                },
            };
            // draw stencil
            ctx.setUniforms(command_encoder, call.uniform_offset);
            const pass_encoder = ctx.startEncoding(command_encoder, desc);
            pass_encoder.setPipeline(ctx.pass.fill.stencil);
            ctx.setTextures(pass_encoder, call);

            for (paths) |path| {
                pass_encoder.draw((path.fill_count - 2) * 3, 1, path.fill_offset, 0);
            }
            pass_encoder.end();
            pass_encoder.release();
        }

        ctx.setUniforms(command_encoder, call.uniform_offset + 1);
        const desc = gpu.RenderPassDescriptor{
            .label = "fill render pass 2",
            .color_attachments = &[1]gpu.RenderPassColorAttachment{
                .{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                    .clear_value = clear_value,
                },
            },
            .color_attachment_count = 1,
            .depth_stencil_attachment = &gpu.RenderPassDepthStencilAttachment{
                .view = ctx.depth_stencil_view.?,
                .stencil_load_op = .load,
                .stencil_store_op = .store,
            },
        };

        // Draw fill
        const pass_encoder = ctx.startEncoding(command_encoder, desc);
        pass_encoder.setPipeline(ctx.pass.fill.fill);
        ctx.setTextures(pass_encoder, call);
        pass_encoder.draw(call.triangle_count, 1, call.triangle_offset, 0);

        pass_encoder.end();
        pass_encoder.release();
    }

    fn convexFill(
        call: Call,
        ctx: *const WebGPUContext,
        command_encoder: *gpu.CommandEncoder,
        back_buffer_view: *gpu.TextureView,
    ) void {
        ctx.setUniforms(command_encoder, call.uniform_offset);

        const desc = gpu.RenderPassDescriptor{
            .label = "convexfill render pass",
            .color_attachments = &[1]gpu.RenderPassColorAttachment{
                .{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                    .clear_value = clear_value,
                },
            },
            .color_attachment_count = 1,
        };
        const pass_encoder = ctx.startEncoding(command_encoder, desc);

        ctx.setTextures(pass_encoder, call);

        const paths = ctx.paths.items[call.path_offset..][0..call.path_count];

        for (paths) |path| {
            pass_encoder.setPipeline(ctx.pass.convex.fill);
            pass_encoder.draw((path.fill_count - 2) * 3, 1, path.fill_offset, 0);
            // Draw fringes
            pass_encoder.setPipeline(ctx.pass.convex.fringe);
            if (path.stroke_count > 0) {
                pass_encoder.draw(path.stroke_count, 1, path.stroke_offset, 0);
            }
        }
        pass_encoder.end();
        pass_encoder.release();
    }

    fn stroke(
        call: Call,
        ctx: *const WebGPUContext,
        command_encoder: *gpu.CommandEncoder,
        back_buffer_view: *gpu.TextureView,
    ) void {
        const paths = ctx.paths.items[call.path_offset..][0..call.path_count];

        const desc = gpu.RenderPassDescriptor{
            .label = "stroke render pass",
            .color_attachments = &[1]gpu.RenderPassColorAttachment{
                .{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                    .clear_value = clear_value,
                },
            },
            .color_attachment_count = 1,
        };
        ctx.setUniforms(command_encoder, call.uniform_offset);
        const pass_encoder = ctx.startEncoding(command_encoder, desc);
        pass_encoder.setPipeline(ctx.pass.stroke.basic);

        ctx.setTextures(pass_encoder, call);

        // Draw Strokes
        for (paths) |path| {
            pass_encoder.draw(path.stroke_count, 1, path.stroke_offset, 0);
        }
        pass_encoder.end();
        pass_encoder.release();
    }

    fn triangles(
        call: Call,
        ctx: *const WebGPUContext,
        command_encoder: *gpu.CommandEncoder,
        back_buffer_view: *gpu.TextureView,
    ) void {
        const desc = gpu.RenderPassDescriptor{
            .label = "triangle render pass",
            .color_attachments = &[1]gpu.RenderPassColorAttachment{
                .{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                    .clear_value = clear_value,
                },
            },
            .color_attachment_count = 1,
        };
        ctx.setUniforms(command_encoder, call.uniform_offset);

        const pass_encoder = ctx.startEncoding(command_encoder, desc);
        pass_encoder.setPipeline(ctx.pass.tri.pipeline);

        ctx.setTextures(pass_encoder, call);

        pass_encoder.draw(call.triangle_count, 1, call.triangle_offset, 0);

        pass_encoder.end();
        pass_encoder.release();
    }
};

fn renderCreate(uptr: *anyopaque) !void {
    const ctx = WebGPUContext.castPtr(uptr);

    try ctx.pass.init(ctx.device, ctx.swap_chain_format);
}

fn renderCreateTexture(uptr: *anyopaque, tex_type: internal.TextureType, w: u32, h: u32, flags: nvg.ImageFlags, data: ?[]const u8) !i32 {
    const ctx = WebGPUContext.castPtr(uptr);

    var tex = try ctx.allocTexture();

    const tex_size = gpu.Extent3D{
        .width = @intCast(w),
        .height = @intCast(h),
    };

    const format: gpu.Texture.Format = switch (tex_type) {
        .none => .undefined,
        .rgba => .rgba8_unorm,
        .alpha => .r8_unorm,
    };

    const texture = ctx.device.createTexture(&gpu.Texture.Descriptor{
        .label = "nanovg texture",
        .size = tex_size,
        .format = format,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
        },
    });

    // TODO: flags.generate_mipmaps

    const bind_group: [2]*gpu.BindGroup = .{
        ctx.device.createBindGroup(&gpu.BindGroup.Descriptor{
            .label = "nanovg texture bind group 1",
            .layout = ctx.pass.texture_layout,
            .entries = &[1]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.textureView(0, texture.createView(&gpu.TextureView.Descriptor{
                    .label = "nanovg texture view 0",
                    .dimension = .dimension_2d,
                })),
            },
            .entry_count = 1,
        }),
        ctx.device.createBindGroup(&gpu.BindGroup.Descriptor{
            .label = "nanovg texture bind group 2",
            .layout = ctx.pass.texture_layout,
            .entries = &[1]gpu.BindGroup.Entry{
                gpu.BindGroup.Entry.textureView(0, texture.createView(&gpu.TextureView.Descriptor{
                    .label = "nanovg texture view 1",
                    .dimension = .dimension_2d,
                })),
            },
            .entry_count = 1,
        }),
    };

    const color_size: u32 = if (tex_type == .rgba) 4 else 1;

    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(w)) * color_size,
        .rows_per_image = @intCast(h),
    };

    if (data) |data_raw| {
        ctx.device.getQueue().writeTexture(
            &gpu.ImageCopyTexture{ .texture = texture },
            &data_layout,
            &tex_size,
            data_raw[0 .. data_layout.bytes_per_row * data_layout.rows_per_image],
        );
    }

    tex.flags = flags;
    tex.tex = texture;
    tex.size = tex_size;
    tex.tex_type = tex_type;
    tex.bind_group = bind_group;
    tex.data_layout = data_layout;
    return tex.id;
}

fn renderDeleteTexture(uptr: *anyopaque, image: i32) void {
    const ctx = WebGPUContext.castPtr(uptr);
    const tex = ctx.removeTexture(image) orelse return;
    tex.bind_group[0].release();
    tex.bind_group[1].release();
    tex.tex.destroy();
    tex.tex.release();
}

fn renderUpdateTexture(uptr: *anyopaque, image: i32, x_arg: u32, y: u32, w_arg: u32, h: u32, data_arg: ?[]const u8) i32 {
    const ctx = WebGPUContext.castPtr(uptr);
    _ = x_arg;
    _ = w_arg;
    const tex = ctx.getTexture(image) orelse return 0;

    switch (tex.tex_type) {
        .none => {},
        .alpha, .rgba => {
            const color_size: u32 = if (tex.tex_type == .rgba) 4 else 1;
            const y0 = @as(u32, @intCast(y)) * tex.size.width;
            const data: [*]const u8 = @ptrCast(&data_arg.?[y0 * color_size]);
            const x = 0;
            const w = tex.size.width;

            const texture = tex.tex;
            ctx.device.getQueue().writeTexture(
                &gpu.ImageCopyTexture{ .texture = texture, .origin = .{ .x = x, .y = @intCast(y) } },
                &tex.data_layout,
                &.{ .width = @as(u32, @intCast(w)), .height = @as(u32, @intCast(h)) },
                data[0 .. color_size * w * @as(u32, @intCast(h))],
            );
        },
    }
    return 1;
}

fn renderGetTextureSize(uptr: *anyopaque, image: i32, w: *u32, h: *u32) i32 {
    const ctx = WebGPUContext.castPtr(uptr);
    const tex = ctx.getTexture(image) orelse return 0;
    w.* = @intCast(tex.size.width);
    h.* = @intCast(tex.size.height);
    return 1;
}

fn renderViewport(uptr: *anyopaque, width: f32, height: f32, devicePixelRatio: f32) void {
    const ctx = WebGPUContext.castPtr(uptr);
    if (width != ctx.view[0] or height != ctx.view[1]) {
        if (ctx.depth_stencil_view) |view| {
            view.release();
        }
        if (ctx.depth_stencil) |tex| {
            tex.destroy();
            tex.release();
        }
        const buffer_size = gpu.Extent3D{
            .width = @intFromFloat(width * devicePixelRatio),
            .height = @intFromFloat(height * devicePixelRatio),
        };
        ctx.depth_stencil = ctx.device.createTexture(&gpu.Texture.Descriptor{
            .label = "nanovg depth/stencil texture",
            .size = buffer_size,
            .format = .stencil8,
            .usage = .{
                .render_attachment = true,
            },
        });
        ctx.depth_stencil_view = ctx.depth_stencil.?.createView(&gpu.TextureView.Descriptor{
            .label = "nanovg depth/stencil texture view",
            .dimension = .dimension_2d,
        });
    }
    ctx.view[0] = width;
    ctx.view[1] = height;
}

fn renderCancel(uptr: *anyopaque) void {
    const ctx = WebGPUContext.castPtr(uptr);
    ctx.verts.clearRetainingCapacity();
    ctx.paths.clearRetainingCapacity();
    ctx.calls.clearRetainingCapacity();
    ctx.uniforms.clearRetainingCapacity();
}

fn renderFlush(uptr: *anyopaque) void {
    const ctx = WebGPUContext.castPtr(uptr);
    if (ctx.calls.items.len > 0) {
        const command_encoder = ctx.device.createCommandEncoder(null);
        command_encoder.writeBuffer(ctx.pass.view_buf, 0, &ctx.view);

        const required_size = ctx.verts.items.len * @sizeOf(internal.Vertex);
        if (required_size > ctx.pass.vert_size) {
            ctx.pass.vert_buf.destroy();
            ctx.pass.vert_buf = ctx.device.createBuffer(&gpu.Buffer.Descriptor{
                .label = "nanovg vertex buffer",
                .usage = .{
                    .vertex = true,
                    .copy_dst = true,
                },
                // TODO: better initial size
                .size = required_size,
            });
            ctx.pass.vert_size = required_size;
        }
        command_encoder.writeBuffer(ctx.pass.vert_buf, 0, ctx.verts.items);

        const back_buffer_view = ctx.swap_chain.*.getCurrentTextureView() orelse return;
        defer back_buffer_view.release();
        for (ctx.calls.items) |call| {
            // TODO: equivalent of glBlendFuncSeparate()
            switch (call.call_type) {
                .none => {},
                .fill => call.fill(ctx, command_encoder, back_buffer_view),
                .convexfill => call.convexFill(ctx, command_encoder, back_buffer_view),
                .stroke => call.stroke(ctx, command_encoder, back_buffer_view),
                .triangles => call.triangles(ctx, command_encoder, back_buffer_view),
            }
        }

        var command = command_encoder.finish(null);
        command_encoder.release();
        ctx.device.getQueue().submit(&[1]*const gpu.CommandBuffer{command});
        command.release();

        ctx.verts.clearRetainingCapacity();
        ctx.paths.clearRetainingCapacity();
        ctx.calls.clearRetainingCapacity();
        ctx.uniforms.clearRetainingCapacity();
    }
}

fn renderFill(
    uptr: *anyopaque,
    paint: *nvg.Paint,
    composite_operation: nvg.CompositeOperationState,
    scissor: *internal.Scissor,
    bounds: [4]f32,
    clip_paths: []const internal.Path,
    paths: []const internal.Path,
) void {
    _ = clip_paths;
    const ctx = WebGPUContext.castPtr(uptr);

    const call = ctx.calls.addOne(ctx.allocator) catch return;
    errdefer _ = ctx.calls.pop();

    // TODO: blending?
    _ = composite_operation;

    const convex = if (paths.len == 1 and paths[0].convex) true else false;
    call.* = Call{
        .call_type = if (convex) .convexfill else .fill,
        .triangle_offset = 0,
        .triangle_count = if (convex) 0 else 4,
        .path_offset = @intCast(ctx.paths.items.len),
        .path_count = @intCast(paths.len),
        .image = paint.image.handle,
        .colormap = paint.colormap.handle,
        .uniform_offset = @intCast(ctx.uniforms.items.len),
        // TODO: blending?
    };

    ctx.paths.ensureUnusedCapacity(ctx.allocator, paths.len) catch return;

    // Allocate vertices for all the paths.
    const max_verts = maxVertCount(paths) + call.triangle_count;
    ctx.verts.ensureUnusedCapacity(ctx.allocator, max_verts) catch return;

    for (paths) |path| {
        const copy = ctx.paths.addOneAssumeCapacity();
        copy.* = std.mem.zeroes(Path);
        if (path.fill.len > 0) {
            copy.fill_offset = @intCast(ctx.verts.items.len);
            copy.fill_count = @intCast(path.fill.len);
            // BUG: need to turn triangle fan into individual triangles as webgpu doesn't support triangle fan topology
            const v0 = path.fill[0];
            for (path.fill[1 .. path.fill.len - 1], path.fill[2..]) |vert1, vert2| {
                ctx.verts.appendAssumeCapacity(v0);
                ctx.verts.appendAssumeCapacity(vert1);
                ctx.verts.appendAssumeCapacity(vert2);
                // ctx.verts.appendSliceAssumeCapacity(path.fill);
            }
        }
        if (path.stroke.len > 0) {
            copy.stroke_offset = @intCast(ctx.verts.items.len);
            copy.stroke_count = @intCast(path.stroke.len);
            ctx.verts.appendSliceAssumeCapacity(path.stroke);
        }
    }

    // Setup uniforms for draw calls
    if (call.call_type == .fill) {
        // Quad
        call.triangle_offset = @intCast(ctx.verts.items.len);
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[3], .u = 0.5, .v = 1.0 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[1], .u = 0.5, .v = 1.0 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[3], .u = 0.5, .v = 1.0 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[1], .u = 0.5, .v = 1.0 });

        ctx.uniforms.ensureUnusedCapacity(ctx.allocator, 2) catch return;
        // Simple shader for stencil
        const frag = ctx.uniforms.addOneAssumeCapacity();
        frag.* = std.mem.zeroes(FragUniforms);
        frag.shader_type = @floatFromInt(@intFromEnum(ShaderType.simple));
        // Fill shader
        _ = ctx.uniforms.addOneAssumeCapacity().fromPaint(paint, scissor, ctx);
    } else {
        ctx.uniforms.ensureUnusedCapacity(ctx.allocator, 1) catch return;
        // Fill shader
        _ = ctx.uniforms.addOneAssumeCapacity().fromPaint(paint, scissor, ctx);
    }
}

fn renderStroke(
    uptr: *anyopaque,
    paint: *nvg.Paint,
    composite_operation: nvg.CompositeOperationState,
    scissor: *internal.Scissor,
    bounds: [4]f32,
    clip_paths: []const internal.Path,
    paths: []const internal.Path,
) void {
    const ctx = WebGPUContext.castPtr(uptr);

    // TODO: blending?
    _ = composite_operation;
    _ = clip_paths;

    const call = ctx.calls.addOne(ctx.allocator) catch return;
    call.* = Call{
        .call_type = .stroke,
        .path_offset = @intCast(ctx.paths.items.len),
        .path_count = @intCast(paths.len),
        .image = paint.image.handle,
        .colormap = paint.colormap.handle,
        .triangle_offset = 0,
        .triangle_count = 0,
        .uniform_offset = @intCast(ctx.uniforms.items.len),
        // TODO: blending?
    };

    // Allocate vertices for all the paths.
    const maxverts = maxVertCount(paths);
    ctx.verts.ensureUnusedCapacity(ctx.allocator, maxverts) catch return;

    if (call.triangle_count > 0) {
        call.triangle_offset = @intCast(ctx.verts.items.len);
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[3], .u = 0.5, .v = 1 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[1], .u = 0.5, .v = 1 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[3], .u = 0.5, .v = 1 });
        ctx.verts.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[1], .u = 0.5, .v = 1 });
    }

    ctx.paths.ensureUnusedCapacity(ctx.allocator, paths.len) catch return;
    // call.blend_func = Blend.fromOperation(composite_operation);

    for (paths) |path| {
        const copy = ctx.paths.addOneAssumeCapacity();
        copy.* = std.mem.zeroes(Path);
        if (path.stroke.len > 0) {
            copy.stroke_offset = @intCast(ctx.verts.items.len);
            copy.stroke_count = @intCast(path.stroke.len);
            ctx.verts.appendSliceAssumeCapacity(path.stroke);
        }
    }

    // Fill shader
    _ = ctx.uniforms.ensureUnusedCapacity(ctx.allocator, 1) catch return;
    _ = ctx.uniforms.addOneAssumeCapacity().fromPaint(paint, scissor, ctx);
}

fn renderTriangles(
    uptr: *anyopaque,
    paint: *nvg.Paint,
    comp_op: nvg.CompositeOperationState,
    scissor: *internal.Scissor,
    verts: []const internal.Vertex,
) void {
    const ctx = WebGPUContext.castPtr(uptr);

    // TODO: blending?
    _ = comp_op;

    const call = ctx.calls.addOne(ctx.allocator) catch return;
    call.* = Call{
        .call_type = .triangles,
        .image = paint.image.handle,
        .colormap = paint.colormap.handle,
        .path_offset = 0,
        .path_count = 0,
        // TODO: blending?
        .triangle_offset = @intCast(ctx.verts.items.len),
        .triangle_count = @intCast(verts.len),
        .uniform_offset = @intCast(ctx.uniforms.items.len),
    };

    ctx.verts.appendSlice(ctx.allocator, verts) catch return;
    const frag = ctx.uniforms.addOne(ctx.allocator) catch return;
    _ = frag.fromPaint(paint, scissor, ctx);
    frag.shader_type = @floatFromInt(@intFromEnum(ShaderType.image));
}

fn renderDelete(uptr: *anyopaque) void {
    const ctx = WebGPUContext.castPtr(uptr);
    ctx.deinit();
}
