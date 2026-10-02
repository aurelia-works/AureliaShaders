#version 330 compatibility

#include "/lib/color.glsl"

out vec2 texcoord;
out vec4 vertexColor;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vertexColor = aureliaDecodeVertexColor(gl_Color);
}
