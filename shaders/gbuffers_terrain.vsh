#version 330 compatibility

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vertexColor;
out vec3 worldNormal;
out vec3 viewPosition;
out vec3 playerPosition;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = clamp(lmcoord / (30.0 / 32.0) - (1.0 / 32.0), 0.0, 1.0);
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();
    worldNormal = mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal);
    viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
}
