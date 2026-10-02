#version 330 compatibility

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec4 entityColor;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 viewPosition;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    vec4 albedo = aureliaDecodeSrgbModulation(texture(gtexture, texcoord), vertexColor);
    if (albedo.a < alphaTestRef) discard;

    vec3 color = aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition);
    color = aureliaApplyFog(color, viewPosition);
    // Preserve Minecraft's hurt/team overlay without an extra material path.
    // entityColor is another Minecraft sRGB color input; its alpha is a
    // coverage/overlay weight and remains linear.
    color = mix(color, aureliaSrgbToLinear(entityColor.rgb), entityColor.a * 0.35);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowVisibility(playerPosition, worldNormal, aureliaShadowDirection(), aureliaSunVisibility(), rainStrength));
#endif
    aureliaSceneColor = vec4(color, albedo.a);
}
