// Terrain fragment stage, shared by gbuffers_terrain (cutout layers) and
// gbuffers_terrain_solid (the solid layer). The wrapper declares the outputs
// (colortex0 scene colour, colortex1 G-buffer) and, for the solid layer,
// AURELIA_TERRAIN_SOLID, which drops the alpha test.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#define AURELIA_TERRAIN_FRAGMENT
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"

uniform sampler2D gtexture;
#ifndef AURELIA_TERRAIN_SOLID
uniform float alphaTestRef;
#endif

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 playerPosition;
in vec4 fogTerms;
flat in int aureliaBlockId;

void main() {
    vec4 texel = texture(gtexture, texcoord);
#ifndef AURELIA_TERRAIN_SOLID
    if (texel.a < alphaTestRef) discard;
#endif
    // separateAo: Iris leaves vanilla's ambient occlusion in the vertex alpha
    // instead of baking it into the colour. It occludes the indirect light
    // only; the sun's own occlusion is the shadow map's job.
    vec3 albedo = aureliaSrgbToLinear(texel.rgb) * vertexColor.rgb;
    float ao = vertexColor.a;
    vec3 normal = normalize(worldNormal);
    AureliaMaterial material = aureliaMaterial(aureliaBlockId, albedo);
#ifdef AURELIA_WET_TERRAIN
    aureliaWetSurface(albedo, material, normal, playerPosition, lmcoord.y);
#endif

    float shadow;
    vec3 color = aureliaShade(albedo, normal, lmcoord, playerPosition, material, ao, shadow);
    color = aureliaApplyFogTerms(color, fogTerms);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowDebug(playerPosition, worldNormal));
#endif
#ifdef AURELIA_TERRAIN_SOLID
    aureliaSceneColor = vec4(color, 1.0);
#else
    aureliaSceneColor = vec4(color, texel.a);
#endif
    aureliaGbuffer = aureliaEncodeGbuffer(normal, material.smoothness, material.metal, lmcoord.y);
}
