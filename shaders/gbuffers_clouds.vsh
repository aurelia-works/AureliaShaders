#version 330 compatibility

// Cloud vertex stage: the minimum gbuffers_clouds needs. 1.20.1 cloud geometry
// is a camera-relative heightfield skin; gl_Vertex in view space gives the
// camera-relative player-space position the fog function consumes. No normals
// exist on vanilla clouds and lighting here is analytical, so none are emitted.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

out vec2 texcoord;
out vec4 vertexColor;
out vec3 playerPosition;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();
    vec3 viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
}
