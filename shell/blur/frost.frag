#version 440
// One card's share of the blurred screen: the part of it the card is over,
// cut to the card's rounded shape.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 area;       // where the card is, in the blurred texture's 0..1
    vec2 size;       // the card's size, in pixels
    float radius;    // its corner radius, in pixels
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 color = texture(source, area.xy + qt_TexCoord0 * area.zw);
    vec2 p = (qt_TexCoord0 - 0.5) * size;
    vec2 q = abs(p) - (size * 0.5 - vec2(radius));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float inside = clamp(0.5 - d, 0.0, 1.0);
    fragColor = color * inside * qt_Opacity;
}
