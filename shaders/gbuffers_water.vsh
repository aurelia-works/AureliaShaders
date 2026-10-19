#version 330 compatibility

// Translucent blocks: water, stained glass, ice, slime, honey and portals.
// All shading is per pixel (gbuffers_water.fsh); this stage passes the face,
// the position in view and player space, and the block.properties ID.
// worldNormal stays unnormalised across the quad (constant per face).

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

in vec4 mc_Entity;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vertexColor;
out vec3 worldNormal;
out vec3 viewPosition;
out vec3 playerPosition;
flat out int aureliaBlockId;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = clamp((lmcoord - 1.0 / 32.0) * (32.0 / 30.0), 0.0, 1.0);
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();
    worldNormal = mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal);
    viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    aureliaBlockId = int(mc_Entity.x + 0.5);
}
