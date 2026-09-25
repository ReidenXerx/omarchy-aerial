#version 440
// Hyprland 0.56 blur2: one dual-Kawase upsample. `texel` is one pixel of the
// level being read, as in down.frag.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;
    float radius;
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 uv = qt_TexCoord0;
    // Hyprland's upsample half-pixel is a quarter of the downsample's.
    vec2 h = texel * radius * 0.25;
    vec4 sum = texture(source, uv + vec2(-h.x * 2.0, 0.0));
    sum += texture(source, uv + vec2(-h.x,  h.y)) * 2.0;
    sum += texture(source, uv + vec2(0.0,   h.y * 2.0));
    sum += texture(source, uv + vec2(h.x,   h.y)) * 2.0;
    sum += texture(source, uv + vec2(h.x * 2.0, 0.0));
    sum += texture(source, uv + vec2(h.x,  -h.y)) * 2.0;
    sum += texture(source, uv + vec2(0.0,  -h.y * 2.0));
    sum += texture(source, uv + vec2(-h.x, -h.y)) * 2.0;
    fragColor = (sum / 12.0) * qt_Opacity;
}
