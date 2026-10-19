#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#define AURELIA_SKY_LUT_READ
#include "/lib/atmosphere.glsl"
#define AURELIA_SUN_EFFECTS_VERTEX
#include "/lib/sun_effects.glsl"

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
#ifdef AURELIA_SUN_EFFECTS
    // Sun position and visibility, once per vertex (lib/sun_effects.glsl).
    aureliaWriteSunEffects();
#endif
}
