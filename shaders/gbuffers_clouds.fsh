#version 330 compatibility

// Cloud pass: Minecraft's vanilla clouds. This pack previously had no cloud
// program, so Iris fell back to gbuffers_textured, whose only job is "leave
// the vanilla look alone" - clouds therefore rendered as the raw texture with
// no relationship to our sky, fog or light, which is what made them read as a
// flat white slab against the gradient.
//
// This program keeps the vanilla cloud texture (we have no volumetric cloud
// system yet - that is the later clouds phase) but re-lights it in one place:
//
//   - sRGB decode, consistent with the rest of the pack;
//   - lit with the contract sun colour by facing (a soft directional term);
//   - pulled toward the sky colour so cloud tint follows time of day;
//   - the pack's exponential fog at cloud height, so clouds fade like terrain.
//
// No shadow lookup: through-cloud shadows need a volumetric layer to be right.
// No normals are provided by this pass in 1.20.1, so lighting stays analytical.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 vertexColor;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    aureliaSceneColor = vec4(1.0);
#else
    vec4 textureColor = texture(gtexture, texcoord);
    if (textureColor.a < 0.01) discard;

    vec3 color = aureliaSrgbToLinear(textureColor.rgb) * vertexColor.rgb;

    // Cloud tint follows the sky. The sun colour keeps golden-hour clouds
    // golden instead of grey-blue slabs.
    vec3 sunDirection = aureliaSunDirection();
    float day = aureliaSunVisibility();
    vec3 sunTint = aureliaSunColor(max(sunDirection.y, 0.0));
    vec3 tint = mix(aureliaSkyColorLinear(), sunTint, 0.22 * day);
    color *= mix(vec3(1.0), tint, 0.35);

    // Cheap directional shading: cloud tops are nominally sun-facing.
    float top = clamp(sunDirection.y, 0.0, 1.0);
    color *= 0.82 + 0.18 * top;

#ifdef AURELIA_CLOUDS_SOFT
    // Soft cloud treatment (P4): analytic character on the vanilla slab. ALU
    // only: a few smoothsteps, one pow and two luma dots; no texture read,
    // no extra pass, no new buffer.
    // The texture alpha doubles as pseudo-thickness: dense cores shade
    // slightly while thin edges stay bright, which reads as self-depth.
    float core = smoothstep(0.30, 0.90, textureColor.a);
    color *= 1.05 - 0.15 * core;

    // Sun-relative warmth: the whole deck picks up the contract sunset colour
    // through the same golden-hour bell the sky dome uses (luminance-
    // preserving, so it tints without blowing out), plus a sunward gradient
    // for extra warmth near the disc. Zero at noon and, via day, at night.
    float sunward = max(dot(normalize(playerPosition + vec3(0.0, 1e-3, 0.0)), sunDirection), 0.0);
    float golden = aureliaHorizonFactor(max(sunDirection.y, 0.0)) * day;
    float cloudLuma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float warm = golden * (0.30 + 0.45 * pow(sunward, 3.0));
    color = mix(color, sunTint * max(cloudLuma, 1e-3), warm);

    // Rain response: desaturate toward luma and darken, keyed to rainStrength
    // with the same flatten weight the sky dome uses. No parallel palette.
    float rain = clamp(rainStrength, 0.0, 1.0);
    float rainLuma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(color, vec3(rainLuma), AURELIA_RAIN_SKY_FLATTEN * rain);
    color *= 1.0 - 0.30 * rain;

    // Softened silhouettes: the fringe alpha is eaten away so cloud edges
    // dissolve instead of cutting hard, while body coverage (alpha above the
    // ramp) is untouched. Multiplicative, so it can only ever fade the edge.
    float softAlpha = textureColor.a * smoothstep(0.0, 0.30, textureColor.a);
#else
    float softAlpha = textureColor.a;
#endif

    // Fog at cloud height fades distant clouds into the sky so they no longer
    // end in a hard edge against the gradient. playerPosition's length is the
    // camera-relative distance in world axes, which is the right metric here.
    color = aureliaApplyFogContract(color, playerPosition, AURELIA_FOG_DENSITY, rainStrength);

    aureliaSceneColor = vec4(color, softAlpha * vertexColor.a);
#endif
}
