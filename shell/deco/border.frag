#version 440
// Hyprland 0.56 window border (border.glsl, with rounding), for one card:
// the same ring, antialiased the same way, in physical pixels of the
// border's box.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 color;          // straight, not premultiplied
    vec2 fullSize;
    float radius;        // inner rounding plus the border
    float radiusOuter;
    float thick;
    float roundingPower;
};

#define M_PI               3.1415926535897932384626433832795
#define SMOOTHING_CONSTANT (M_PI / 5.34665792551)

void main() {
    vec2 originalPixCoord = qt_TexCoord0 * fullSize;
    vec2 pixCoord = originalPixCoord - fullSize * 0.5;
    pixCoord *= vec2(lessThan(pixCoord, vec2(0.0))) * -2.0 + 1.0;
    vec2 pixCoordOuter = pixCoord;
    pixCoord -= fullSize * 0.5 - radius;
    pixCoordOuter -= fullSize * 0.5 - radiusOuter;
    pixCoord += vec2(1.0, 1.0) / fullSize;
    pixCoordOuter += vec2(1.0, 1.0) / fullSize;

    float additionalAlpha = 1.0;
    bool done = false;

    if (min(pixCoord.x, pixCoord.y) > 0.0 && radius > 0.0) {
        float dist      = pow(pow(pixCoord.x, roundingPower) + pow(pixCoord.y, roundingPower), 1.0 / roundingPower);
        float distOuter = pow(pow(pixCoordOuter.x, roundingPower) + pow(pixCoordOuter.y, roundingPower), 1.0 / roundingPower);
        float h         = thick / 2.0;
        if (dist < radius - h) {
            additionalAlpha *= smoothstep(0.0, 1.0, (dist - radius + thick + SMOOTHING_CONSTANT) / (SMOOTHING_CONSTANT * 2.0));
            done = true;
        } else if (min(pixCoordOuter.x, pixCoordOuter.y) > 0.0) {
            additionalAlpha *= 1.0 - smoothstep(0.0, 1.0, (distOuter - radiusOuter + SMOOTHING_CONSTANT) / (SMOOTHING_CONSTANT * 2.0));
            done = true;
        } else if (distOuter < radiusOuter - h) {
            additionalAlpha = 1.0;
            done = true;
        }
    }

    if (!done) {
        float smallest = min(min(originalPixCoord.y, fullSize.y - originalPixCoord.y),
                             min(originalPixCoord.x, fullSize.x - originalPixCoord.x));
        if (smallest > thick)
            additionalAlpha = 0.0;
    }

    fragColor = vec4(color.rgb * color.a, color.a) * additionalAlpha * qt_Opacity;
}
