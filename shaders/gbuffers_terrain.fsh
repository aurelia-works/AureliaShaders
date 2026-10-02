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
    color = vec3(aureliaShadowDebug(playerPosition, worldNormal));
#endif
    aureliaSceneColor = vec4(color, albedo.a);
}
