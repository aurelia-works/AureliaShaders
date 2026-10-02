#version 330 compatibility

// Cloud pass: Minecraft's vanilla cloud geometry, re-lit by the pack.
//
// Face lighting (sun/moon wrap, golden rim, overcast, night) is evaluated per
// vertex in gbuffers_clouds.vsh from the real face normals; this stage adds the
// only per-pixel terms that depend on the view ray and applies the pack's fog:
//
//   - alpha from the cloud texture (the vanilla shape; the texture's alpha is
//     binary, so no edge softening is attempted on it);
//   - under AURELIA_CLOUDS_SOFT: a sun-ward silver lining on vertical faces and
//     a golden-hour warmth gradient toward the sun;
//   - the pack's fog at cloud distance so the far deck dissolves into the sky.
//
// Vanilla draws fancy clouds twice (a colour-masked depth prepass, then the
// colour pass). Both run this program; the prepass's colour is masked off by
// the game, and the alpha test below keeps its depth footprint identical.
//
// No shadow lookup: clouds neither receive nor cast through this layer.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

// Share of the pack's fog density applied at cloud height.
const float AURELIA_CLOUD_FOG_SHARE = 0.45;

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 cloudLight;
in float cloudSide;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    aureliaSceneColor = vec4(1.0);
#else
    vec4 textureColor = texture(gtexture, texcoord);
    // Vanilla's cloud shader discards below 0.1 as well.
    if (textureColor.a < 0.1) discard;

    // The cloud texture is white; its RGB only matters to a resource pack that
    // tints it. Squaring is the cheap sRGB decode - it is multiplied by 1.0 in
    // the shipped texture, so the approximation error is zero there.
    vec3 color = cloudLight.rgb * (textureColor.rgb * textureColor.rgb);

#ifdef AURELIA_CLOUDS_SOFT
    vec3 viewDirection = normalize(playerPosition + vec3(0.0, 1e-4, 0.0));
    vec3 sunDirection = aureliaSunDirection();
    float day = aureliaSunVisibility();
    float rain = clamp(rainStrength, 0.0, 1.0);
    vec3 sunTint = aureliaSunColor(max(sunDirection.y, 0.0));
    float sunward = max(dot(viewDirection, sunDirection), 0.0);

    // Golden-hour warmth: the whole deck leans toward the contract sunset
    // colour through the same bell the sky dome uses (luminance-preserving),
    // strongest toward the sun. Zero at noon, at night and (via 1 - rain) under
    // an overcast.
    float golden = aureliaHorizonFactor(max(sunDirection.y, 0.0)) * day * (1.0 - rain);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(color, sunTint * max(luma, 1e-3), golden * (0.25 + 0.45 * sunward * sunward * sunward));

    // Silver lining: looking toward the sun, the thin vertical flanks scatter
    // light forward. Additive, vertical faces only, off in overcast and night.
    float sunward2 = sunward * sunward;
    float sunward4 = sunward2 * sunward2;
    color += sunTint * (0.30 * sunward4 * sunward4 * cloudSide * day * (1.0 - rain));
#endif

    // Fog at cloud distance: playerPosition is camera-relative in WORLD axes,
    // which is both the right distance and the right direction for the fog
    // colour (a view-space vector would tilt the horizon with camera pitch).
    // The deck is far above the haze layer terrain sits in, so it takes a
    // thinner share of the density: at full density the nearest cloud overhead
    // was already half dissolved and the deck read as sky-coloured mush.
    color = aureliaApplyFogContract(color, playerPosition, AURELIA_FOG_DENSITY * AURELIA_CLOUD_FOG_SHARE, rainStrength);

    aureliaSceneColor = vec4(color, textureColor.a * cloudLight.a);
#endif
}
