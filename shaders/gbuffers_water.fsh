#version 330 compatibility

// Phase 2B introduction. This stage mirrors gbuffers_terrain.fsh exactly.
// Iris previously fell back from gbuffers_water to gbuffers_terrain, so an
// explicit pair with identical math keeps rendered water behaviour unchanged
// while bringing the path under Aurelia's ownership. Water is a shadow receiver
// only: shaders.properties keeps shadowTranslucent disabled, so this file
// samples the shadow map but never feeds the caster pass.
// Water-specific shading (Fresnel, reflection, wave normals, depth treatment) is
// a later change; this file deliberately adds none.

#include "/lib/options.glsl"
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 viewPosition;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    vec4 albedo = aureliaDecodeSrgbTerrain(texture(gtexture, texcoord), vertexColor);
    if (albedo.a < alphaTestRef) discard;

    vec3 color = aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition);
    color = aureliaApplyFog(color, viewPosition);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowVisibility(playerPosition, worldNormal, aureliaShadowDirection(), aureliaSunVisibility(), rainStrength));
#endif
    aureliaSceneColor = vec4(color, albedo.a);
}
