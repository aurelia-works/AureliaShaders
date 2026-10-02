#version 330 compatibility

// Weather pass: falling rain and snow. This pack previously had no explicit
// weather program, so Iris fell back to gbuffers_textured_lit and weather quads
// received full terrain-style directional lighting - and, with
// AURELIA_WETNESS_SPECULAR enabled, a Blinn sheen written for solid surfaces -
// which produced a bright white halo of overlapping, over-lit streaks around
// the camera in rain. Weather is not lit geometry; it is a soft translucent
// overlay, and it is the most overdrawn thing in the frame, so this stage is
// kept to one texture read and a handful of ALU ops:
//
//   - no directional sun, no ambient term, no shadow lookup, no sheen;
//   - vertex colour kept as the vignette/opacity input Minecraft authored;
//   - fog arrives as a per-vertex offset + keep factor (see the vertex stage);
//   - alpha survives as coverage, so blending stays vanilla's baked-in falloff.
//
// Rain and snow share this program and Minecraft's two textures. Rain is a
// pale blue-grey and is pulled to a cool, dim neutral so it never outshines the
// overcast dome; snow is pure white and must stay white, only following the
// time of day. The two are told apart by the texture's own chroma, which needs
// no uniform and is correct per quad even where rain and snow biomes meet.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/color.glsl"
#include "/lib/look.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec4 vertexColor;
in vec4 fogTerms;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    // Weather is not a shadow receiver; keep the diagnostic mask true.
    aureliaSceneColor = vec4(1.0);
#else
    vec4 textureColor = texture(gtexture, texcoord);
    if (textureColor.a < alphaTestRef) discard;

    // Squaring is the cheap sRGB decode: weather texels are near-neutral and
    // low-contrast, where 2.0 vs 2.2 is far below one 8-bit step of the result.
    vec3 linear = textureColor.rgb * textureColor.rgb * vertexColor.rgb;

    // Snow: no chroma. Rain: vanilla's blue-grey (chroma well above the ramp).
    float chroma = max(max(textureColor.r, textureColor.g), textureColor.b)
                 - min(min(textureColor.r, textureColor.g), textureColor.b);
    float snow = 1.0 - smoothstep(0.02, 0.07, chroma);

    float day = aureliaSunVisibility();

    // Rain: most of the texture's chroma goes to its own luma, leaving a
    // deliberate cool grey-blue bias. Brightness follows the overcast light
    // instead of a fixed gain, dimmed at night with a small cool lift so near
    // drops stay readable against the navy sky without glowing.
    float luma = dot(linear, vec3(0.2126, 0.7152, 0.0722));
    vec3 rain = mix(vec3(luma), linear, 0.35) * vec3(0.88, 0.94, 1.00) * (mix(0.60, 1.00, day) * 0.85)
              + vec3(0.030, 0.034, 0.041) * (1.0 - 0.65 * day);

    // Snow: white by day; at night a dim cool grey, not an emitter.
    vec3 flake = linear * mix(0.14, 0.90, day);

    vec3 color = mix(rain, flake, snow) * fogTerms.a + fogTerms.rgb;

    // Coverage: the streak alpha is lifted a little so individual drops read,
    // clamped well below 1 so the overlay never becomes a sheet.
    float coverage = min(textureColor.a * vertexColor.a * 1.35, 0.9);
    aureliaSceneColor = vec4(color, coverage);
#endif
}
