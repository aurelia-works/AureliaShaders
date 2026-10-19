// Terrain vertex stage, shared by gbuffers_terrain (cutout layers) and
// gbuffers_terrain_solid (the solid layer) so the two can never drift apart.
// Included right after #version by both wrappers.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"
#include "/lib/waving.glsl"

in vec4 mc_Entity;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vertexColor;
out vec3 worldNormal;
out vec3 playerPosition;
out vec4 fogTerms; // per-vertex fog (lib/sky.glsl aureliaFogTerms)
flat out int aureliaBlockId; // block.properties ID, for lib/materials.glsl

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = clamp((lmcoord - 1.0 / 32.0) * (32.0 / 30.0), 0.0, 1.0);
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();
    worldNormal = mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal);
    // Plants (block.properties 10001/10003/10004) are cross-shaped quads whose real
    // normals are horizontal, so at noon they caught no sun and every grass
    // tuft rendered as a dark X on the lit ground (seen in game). Light them
    // as the ground they stand on: one up-facing normal, no per-pixel cost.
    // Leaves (10002) are tilted most of the way up rather than fully, so
    // canopy sides are not left on fill light alone yet still shade a little
    // (fully up read as flat neon in game). They cast and receive shadows.
    int blockId = int(mc_Entity.x + 0.5);
    aureliaBlockId = blockId;
    if (aureliaIsPlant(blockId)) worldNormal = vec3(0.0, 1.0, 0.0);
    else if (blockId == 10002) worldNormal = normalize(normalize(worldNormal) + vec3(0.0, 1.5, 0.0));
    vec3 viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
#ifdef AURELIA_WAVING
    // World axes, so the same offset moves the vertex in clip space through
    // the full model-view-projection (lib/waving.glsl).
    vec3 wave = aureliaWaveOffset(blockId, texcoord, playerPosition + cameraPosition, rainStrength);
    gl_Position += gl_ModelViewProjectionMatrix * vec4(wave, 0.0);
    playerPosition += wave;
#endif
    fogTerms = aureliaFogTerms(playerPosition, AURELIA_FOG_DENSITY, rainStrength);
}
