#version 330 compatibility

// Weather vertex stage: the minimum the fragment stage needs. No normals, no
// player-space position, no shadow varyings: weather quads are a screen-facing
// overlay and must not inherit any terrain-style lighting inputs, which is what
// the gbuffers_textured_lit fallback was getting wrong.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vertexColor;
out vec3 viewPosition;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = clamp(lmcoord / (30.0 / 32.0) - (1.0 / 32.0), 0.0, 1.0);
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();
    viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
}
