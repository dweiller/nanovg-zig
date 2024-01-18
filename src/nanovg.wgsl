struct Uniforms {
    scissorMat: mat3x4<f32>,
    paintMat: mat3x4<f32>,
    innerCol: vec4<f32>,
    outerCol: vec4<f32>,
    scissorExt: vec2<f32>,
    scissorScale: vec2<f32>,
    extent: vec2<f32>,
    radius: f32,
    feather: f32,
    texType: f32,
    call_type: f32,
}

@group(0) @binding(0)
var<uniform> view: vec2<f32>;
@group(0) @binding(1)
var<uniform> uniforms: Uniforms;
@group(0) @binding(2)
var texture_sampler: sampler;
@group(1) @binding(0)
var texture: texture_2d<f32>;
@group(2) @binding(0)
var color_map: texture_2d<f32>;

struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(1) fpos: vec2<f32>,
    @location(2) uv: vec2<f32>,
}

@vertex
fn vert(@location(0) pos: vec2<f32>, @location(1) uv: vec2<f32>) -> VertexOutput {
    let clip_pos = vec4<f32>(2.0 * pos.x / view.x - 1.0, 1.0 - 2.0 * pos.y / view.y, 0.0, 1.0);
    return VertexOutput(clip_pos, pos, uv);
}

@fragment
fn fragNoEdgeAA(input: VertexOutput) -> @location(0) vec4<f32> {
    let strokeAlpha = 1.0;
    return frag_main(input, strokeAlpha);
}

fn frag_main(input: VertexOutput, strokeAlpha: f32) -> vec4<f32> {
    var result: vec4<f32>;
    let scissor = scissorMask(input.fpos);
    if (uniforms.call_type == 0.0) { // Gradient
        // Calculate gradient color using box gradient
        let pt = (uniforms.paintMat * vec3<f32>(input.fpos, 1.0)).xy;
        let d = clamp((sdroundrect(pt, uniforms.extent, uniforms.radius) + uniforms.feather * 0.5) / uniforms.feather, 0.0, 1.0);
        var color = mix(uniforms.innerCol, uniforms.outerCol, d);
        // Combine alpha
        color *= strokeAlpha * scissor;
        result = color;
    } else if (uniforms.call_type == 1.0) { // Image
        // Calculate color fron texture
        let pt = (uniforms.paintMat * vec3<f32>(input.fpos, 1.0)).xy / uniforms.extent;
        var color = textureSample(texture, texture_sampler, pt);
        if (uniforms.texType == 1.0) {
            color = vec4<f32>(color.xyz * color.w, color.w);
        }
        if (uniforms.texType == 2.0) {
            color = vec4<f32>(color.x);
        }
        if (uniforms.texType == 3.0) {
            color = textureSample(color_map, texture_sampler, vec2<f32>(color.x, 0.5));
            color = vec4<f32>(color.xyz * color.w, color.w);
        }
        // Apply color tint and alpha.
        color *= uniforms.innerCol;
        // Combine alpha
        color *= strokeAlpha * scissor;
        result = color;
    } else if (uniforms.call_type == 2.0) { // Stencil fill
        result = vec4<f32>(1.0, 1.0, 1.0, 1.0);
    } else if (uniforms.call_type == 3.0) { // Textured tris
        var color = textureSample(texture, texture_sampler, input.uv);
        if (uniforms.texType == 1.0) {
            color = vec4<f32>(color.xyz * color.w, color.w);
        }
        if (uniforms.texType == 2.0) {
            color = vec4<f32>(color.x);
        }
        if (uniforms.texType == 3.0) {
            color = textureSample(color_map, texture_sampler, vec2<f32>(color.x, 0.5));
            color = vec4<f32>(color.xyz * color.w, color.w);
        }
        color *= scissor;
        result = color * uniforms.innerCol;
    }
    return result;
}

fn scissorMask(p: vec2<f32>) -> f32 {
    var sc = (abs((uniforms.scissorMat * vec3<f32>(p, 1.0)).xy) - uniforms.scissorExt);
    sc = vec2<f32>(0.5, 0.5) - sc * uniforms.scissorScale;
    return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

fn sdroundrect(pt: vec2<f32>, ext: vec2<f32>, rad: f32) -> f32 {
    let ext2 = ext - vec2<f32>(rad, rad);
    let d = abs(pt) - ext2;
    return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0))) - rad;
}
