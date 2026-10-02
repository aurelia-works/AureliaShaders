#version 330 compatibility

// Weather pass: falling rain and snow. This pack previously had no explicit
// weather program, so Iris fell back to gbuffers_textured_lit and weather quads
// received full terrain-style directional lighting - and, with
// AURELIA_WETNESS_SPECULAR enabled, a Blinn sheen written for solid surfaces -
// which produced a bright white halo of overlapping, over-lit streaks around
// the camera in rain. Weather is not lit geometry; it is a soft translucent
// overlay. This program draws it that way:
//
//   - no directional sun, no ambient term, no shadow lookup, no sheen;
//   - vertex colour kept as the vignette/opacity input Minecraft authored;
//   - one sRGB -> linear decode, consistent with the rest of the pack;
//   - the pack's fog curve so distant rain blends with the sky like terrain;
//   - alpha survives as coverage, so blending stays vanilla's baked-in falloff.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 viewPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    // Weather is not a shadow receiver; keep the diagnostic mask true.
    aureliaSceneColor = vec4(1.0);
#else
    vec4 textureColor = texture(gtexture, texcoord);
    if (textureColor.a < alphaTestRef) discard;

    // Weather texture colour is already authored against the world; the vertex
    // colour carries the local fade/opacity. Both are sRGB inputs; neither is
    // a lighting result.
    vec3 color = aureliaSrgbToLinear(textureColor.rgb)
        * vertexColor.rgb;

    // Neutral-cool rain, fixed at the earliest correct source: vanilla's rain
    // texture is pale blue, and through this pack's curve it read as electric
    // blue - brighter than the overcast dome it falls against. Most of the
    // texture's chroma is pulled toward its own luma, leaving a deliberate
    // cool grey-blue bias rather than pure grey. This multiplies whatever the
    // texture and vertex colour actually are in game, so the fix holds
    // regardless of their exact values.
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, 0.35) * vec3(0.88, 0.94, 1.00);

    // Brightness follows the overcast sky instead of a fixed gain: rain is lit
    // by the same overcast light the dome is, so it reads as weather, not as a
    // light source. Dimmed further at night, with a small cool lift so nearby
    // drops stay readable against the navy sky without glowing. The previous
    // fixed 1.10 gain plus the larger blue lift were tuned while the night sky
    // rendered nearly black; against the accepted navy palette they read as
    // emissive.
    float day = aureliaSunVisibility();
    color *= mix(0.60, 1.00, day) * 0.85;
    color += vec3(0.030, 0.034, 0.041) * (1.0 - 0.65 * day);

    color = aureliaApplyFogContract(color, viewPosition, AURELIA_FOG_DENSITY, rainStrength);
    // Coverage: the streak alpha is lifted a little so individual drops read,
    // clamped well below 1 so the overlay never becomes a sheet.
    float coverage = clamp(textureColor.a * vertexColor.a * 1.35, 0.0, 0.9);
    aureliaSceneColor = vec4(color, coverage);
#endif
}
