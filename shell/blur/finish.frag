#version 440
// Hyprland 0.56 blurfinish: noise, then brightness below 1.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float noise;
    float brightness;
};
layout(binding = 1) uniform sampler2D source;

float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 1689.1984);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec4 pixColor = texture(source, qt_TexCoord0);
    float noiseAmount = hash(qt_TexCoord0) - 0.5;
    pixColor.rgb += noiseAmount * noise;
    pixColor.rgb *= min(1.0, brightness);
    fragColor = pixColor * qt_Opacity;
}
