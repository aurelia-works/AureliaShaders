#version 330 compatibility

#include "/lib/options.glsl"

out vec2 texcoord;
out vec4 vertexColor;

void main() {
    // Iris supplies the shadow camera matrices for this legacy 1.7.x program.
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vertexColor = gl_Color;
}
