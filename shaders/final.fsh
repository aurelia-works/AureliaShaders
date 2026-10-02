#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/tonemap.glsl"
#include "/lib/debug.glsl"

uniform sampler2D colortex0;
uniform float aureliaSmoothedFrameTime;
uniform float aureliaAdaptiveQuality;
uniform float aureliaAdaptiveShadowFilterSamples;

#ifdef AURELIA_DISTANT_RAIN
uniform sampler2D depthtex0;
uniform float frameTimeCounter;
uniform mat4 gbufferProjectionInverse;
#endif

#ifdef AURELIA_DISTANT_RAIN
#include "/lib/distant_rain.glsl"
#endif

#ifdef AURELIA_SHADOWS
// shadowtex0 is hardware-compared (lib/shadows.glsl), so the raw-depth debug
// view reads shadowtex1, which holds the same casters (shadowTranslucent is
// off) without compare mode.
uniform sampler2D shadowtex1;
#endif

in vec2 texcoord;

// One linear floating-point scene target preserves values above 1.0 until the
// ACES-like tone mapper. Iris reads these directives from the comment; keeping
// them out of the GLSL source keeps desktop validators portable.
/*
const int colortex0Format = RGBA16F;
const bool colortex0Clear = true;
const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
*/

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    vec4 scene = texture(colortex0, texcoord);
    vec3 color = scene.rgb;

#if AURELIA_DEBUG_VIEW == 0
    color = scene.rgb;
    #ifdef AURELIA_DISTANT_RAIN
        // The curtain composites into the LINEAR scene before grading, so
        // distant rain goes through the same tonemap/sRGB as everything else.
        color += aureliaDistantRain(texcoord);
    #endif
    color = aureliaGrade(color);
#elif AURELIA_DEBUG_VIEW == 2
    color = aureliaDebugAdaptive(aureliaSmoothedFrameTime, aureliaAdaptiveQuality);
#elif AURELIA_DEBUG_VIEW == 3
    color = scene.rgb;
#elif AURELIA_DEBUG_VIEW == 5
    // The forward passes write a scalar factor into scene.rgb. Collapse any
    // non-receiver pixels to the same scalar and bypass all filmic grading.
    color = vec3(clamp(dot(scene.rgb, vec3(1.0 / 3.0)), 0.0, 1.0));
#elif AURELIA_DEBUG_VIEW == 4
    #ifdef AURELIA_SHADOWS
        color = vec3(texture(shadowtex1, texcoord).r);
    #else
        color = vec3(0.0);
    #endif
#elif AURELIA_DEBUG_VIEW == 6
    color = aureliaDebugShadowBudget(aureliaAdaptiveShadowFilterSamples);
#endif

    // The scene is linear through grading; only display output gets sRGB.
    // Debug modes bypass grading but still receive the display transfer.
    aureliaSceneColor = vec4(aureliaLinearToSrgb(color), scene.a);
}
