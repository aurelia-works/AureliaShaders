#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 vertexColor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    // Sun/moon textures remain Minecraft-authored; final grading unifies them.
#if AURELIA_DEBUG_VIEW == 5
    // Sky pixels do not receive a shadow-map lookup and are therefore fully lit.
    aureliaSceneColor = vec4(1.0);
#else
    aureliaSceneColor = aureliaDecodeSrgbModulation(texture(gtexture, texcoord), vertexColor);
#endif
}
