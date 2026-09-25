#version 440
// Hyprland 0.56 blur1: one dual-Kawase downsample, with vibrancy.
//
// Hyprland renders every level into one monitor-sized buffer and offsets by
// `radius` buffer pixels; here each level is its own texture, so `texel` is
// one pixel of the level being read, and the offsets come out the same.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 texel;
    float radius;
    float passes;
    float vibrancy;
    float vibrancyDarkness;
};
layout(binding = 1) uniform sampler2D source;

const float Pr = 0.299;
const float Pg = 0.587;
const float Pb = 0.114;
const float a = 0.93;
const float b = 0.11;
const float c = 0.66;

float doubleCircleSigmoid(float x, float a) {
    a = clamp(a, 0.0, 1.0);
    float y = .0;
    if (x <= a) {
        y = a - sqrt(a * a - x * x);
    } else {
        y = a + sqrt(pow(1. - a, 2.) - pow(x - 1., 2.));
    }
    return y;
}

vec3 rgb2hsl(vec3 col) {
    float red   = col.r;
    float green = col.g;
    float blue  = col.b;
    float minc  = min(col.r, min(col.g, col.b));
    float maxc  = max(col.r, max(col.g, col.b));
    float delta = maxc - minc;
    float lum = (minc + maxc) * 0.5;
    float sat = 0.0;
    float hue = 0.0;
    if (lum > 0.0 && lum < 1.0) {
        float mul = (lum < 0.5) ? (lum) : (1.0 - lum);
        sat       = delta / (mul * 2.0);
    }
    if (delta > 0.0) {
        vec3 maxcVec = vec3(maxc);
        vec3 masks   = vec3(equal(maxcVec, col)) * vec3(notEqual(maxcVec, vec3(green, blue, red)));
        vec3 adds    = vec3(0.0, 2.0, 4.0) + vec3(green - blue, blue - red, red - green) / delta;
        hue += dot(adds, masks);
        hue /= 6.0;
        if (hue < 0.0)
            hue += 1.0;
    }
    return vec3(hue, sat, lum);
}

vec3 hsl2rgb(vec3 col) {
    const float onethird = 1.0 / 3.0;
    const float twothird = 2.0 / 3.0;
    const float rcpsixth = 6.0;
    float hue = col.x;
    float sat = col.y;
    float lum = col.z;
    vec3 xt = vec3(0.0);
    if (hue < onethird) {
        xt.r = rcpsixth * (onethird - hue);
        xt.g = rcpsixth * hue;
        xt.b = 0.0;
    } else if (hue < twothird) {
        xt.r = 0.0;
        xt.g = rcpsixth * (twothird - hue);
        xt.b = rcpsixth * (hue - onethird);
    } else
        xt = vec3(rcpsixth * (hue - twothird), 0.0, rcpsixth * (1.0 - hue));
    xt = min(xt, 1.0);
    float sat2   = 2.0 * sat;
    float satinv = 1.0 - sat;
    float luminv = 1.0 - lum;
    float lum2m1 = (2.0 * lum) - 1.0;
    vec3  ct     = (sat2 * xt) + satinv;
    vec3  rgb;
    if (lum >= 0.5)
        rgb = (luminv * ct) + lum2m1;
    else
        rgb = lum * ct;
    return rgb;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 o = texel * radius;
    vec4 sum = texture(source, uv) * 4.0;
    sum += texture(source, uv - o);
    sum += texture(source, uv + o);
    sum += texture(source, uv + vec2(o.x, -o.y));
    sum += texture(source, uv - vec2(o.x, -o.y));
    vec4 color = sum / 8.0;

    if (vibrancy != 0.0) {
        float vibrancy_darkness1 = 1.0 - vibrancyDarkness;
        vec3 hsl = rgb2hsl(color.rgb);
        float perceivedBrightness = doubleCircleSigmoid(sqrt(color.r * color.r * Pr + color.g * color.g * Pg + color.b * color.b * Pb), 0.8 * vibrancy_darkness1);
        float b1        = b * vibrancy_darkness1;
        float boostBase = hsl[1] > 0.0 ? smoothstep(b1 - c * 0.5, b1 + c * 0.5, 1.0 - (pow(1.0 - hsl[1] * cos(a), 2.0) + pow(1.0 - perceivedBrightness * sin(a), 2.0))) : 0.0;
        float saturation = clamp(hsl[1] + (boostBase * vibrancy) / passes, 0.0, 1.0);
        color = vec4(hsl2rgb(vec3(hsl[0], saturation, hsl[2])), color[3]);
    }
    fragColor = color * qt_Opacity;
}
