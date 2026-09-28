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
#include "/lib/color.glsl"
#include "/lib/look.glsl"

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
        * aureliaSrgbToLinear(vertexColor.rgb);

    // Sky/fog daylight keeps weather from glowing brighter than the sky behind
    // it. Mild, ALU-only attenuation, not a lighting model.
    color *= 0.86;

    color = aureliaApplyFogContract(color, viewPosition, AURELIA_FOG_DENSITY, rainStrength);
    // Coverage, not a reflection alpha: keep blending predictable.
    aureliaSceneColor = vec4(color, textureColor.a * vertexColor.a);
#endif
}
