#version 440
// Hyprland 0.56 blurprepare: contrast, then brightness above 1.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float contrast;
    float brightness;
};
layout(binding = 1) uniform sampler2D source;

vec3 gain(vec3 src, float k) {
    vec3 x = clamp(src, 0.0, 1.0);
    vec3 t = step(0.5, x);
    vec3 y = mix(x, 1.0 - x, t);
    vec3 a = 0.5 * pow(2.0 * y, vec3(k));
    return mix(a, 1.0 - a, t);
}

void main() {
    vec4 pixColor = texture(source, qt_TexCoord0);
    if (contrast != 1.0)
        pixColor.rgb = gain(pixColor.rgb, contrast);
    pixColor.rgb *= max(1.0, brightness);
    fragColor = pixColor * qt_Opacity;
}
