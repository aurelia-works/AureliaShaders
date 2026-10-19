#version 330 compatibility

// Eye adaptation, metering half (lib/exposure.glsl). Runs on the 1x1
// colortex4: 96 taps of the finished HDR scene on a centre-weighted grid give
// a log-average luminance, which is clamped to the adaptation range and eased
// toward from last frame's value. The eye brightens to a lit room in about a
// second and darkens out of one a little slower.

#include "/lib/options.glsl"
#include "/lib/exposure.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex4;
uniform float frameTime;

/*
const int colortex4Format = RGBA16F;
const bool colortex4Clear = false;
*/

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 aureliaMetered;

void main() {
    float sum = 0.0;
    float weights = 0.0;
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 12; ++x) {
            vec2 uv = (vec2(x, y) + 0.5) / vec2(12.0, 8.0);
            vec3 c = textureLod(colortex0, uv, 0.0).rgb;
            float luminance = dot(c, vec3(0.2126, 0.7152, 0.0722));
            // Centre-weighted, and biased to the lower frame the way a
            // photographer meters a street: the sky is allowed to run bright.
            vec2 offset = (uv - 0.5) * vec2(1.0, 0.8);
            float weight = (1.0 - 1.4 * dot(offset, offset)) * mix(1.3, 0.45, uv.y);
            sum += weight * log2(max(luminance, 1e-6));
            weights += weight;
        }
    }
    float target = clamp(sum / weights, AURELIA_EV_MIN, AURELIA_EV_MAX);
    vec4 history = texelFetch(colortex4, ivec2(0), 0);
    float adapted = target;
    if (history.a > 0.5 && history.r == history.r) {
        // Faster toward bright (pupil closing), slower toward dark.
        float rate = target > history.r ? 2.0 : 1.1;
        adapted = mix(history.r, target, 1.0 - exp(-max(frameTime, 0.0) * rate));
    }
    aureliaMetered = vec4(adapted, target, 0.0, 1.0);
}
