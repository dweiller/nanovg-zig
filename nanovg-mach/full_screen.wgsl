
@vertex
fn vert(@location(0) pos: vec2<f32>) -> @builtin(position) vec4<f32> {
    return vec4<f32>(pos, 0.0, 1.0);
}

@fragment
fn frag(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    discard;
    return vec4<f32>(0, 0, 0, 0);
}
