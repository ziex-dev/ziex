// A triangle spinning around the origin, coloured per vertex.
// Uniforms are written from Zig every frame (see page.zx).

struct Uniforms {
    time: f32,
    aspect: f32,
    _pad: vec2f,
};

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
};

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VertexOut {
    var points = array<vec2f, 3>(vec2f(0.0, 0.62), vec2f(-0.54, -0.31), vec2f(0.54, -0.31));
    var colors = array<vec3f, 3>(vec3f(0.29, 0.87, 0.5), vec3f(0.49, 0.83, 0.99), vec3f(0.98, 0.75, 0.14));
    let s = sin(u.time);
    let c = cos(u.time);
    let p = points[i];
    let rotated = vec2f(p.x * c - p.y * s, p.x * s + p.y * c);

    var out: VertexOut;
    out.position = vec4f(rotated.x / u.aspect, rotated.y, 0.0, 1.0);
    out.color = colors[i];
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
}
