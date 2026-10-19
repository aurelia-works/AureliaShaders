#version 330 compatibility

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 playerPosition;
in vec4 fogTerms;

/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 aureliaSceneColor;
// Opaque programs drawn before deferred.fsh all write the G-buffer, so a mob
// or item in front of a polished wall does not inherit the wall's reflection.
layout(location = 1) out vec4 aureliaGbuffer;

void main() {
    vec4 albedo = aureliaDecodeSrgbModulation(texture(gtexture, texcoord), vertexColor);
    if (albedo.a < alphaTestRef) discard;
    vec3 color = aureliaApplyFogTerms(aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition), fogTerms);
#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowDebug(playerPosition, worldNormal));
#endif
    aureliaSceneColor = vec4(color, albedo.a);
    aureliaGbuffer = vec4(0.0);
}
