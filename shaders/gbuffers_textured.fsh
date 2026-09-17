#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 vertexColor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    // Unlit special geometry (world border, some particles) preserves vanilla
    // intent and avoids inventing normals for a pass that does not provide them.
#if AURELIA_DEBUG_VIEW == 5
    // This pass has no directional receiver term; represent it as fully lit so
    // the diagnostic remains a scalar visibility mask across the whole frame.
    aureliaSceneColor = vec4(1.0);
#else
    aureliaSceneColor = aureliaDecodeSrgbModulation(texture(gtexture, texcoord), vertexColor);
#endif
}
