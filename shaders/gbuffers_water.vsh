#version 330 compatibility

// Phase 2B introduction. This stage mirrors gbuffers_terrain.vsh exactly.
// Iris previously fell back from gbuffers_water to gbuffers_terrain, so an
// explicit pair with identical math keeps rendered water behaviour unchanged
// while bringing the path under Aurelia's ownership. Water-specific shading is a
// later change; this file deliberately adds none.

#include "/lib/options.glsl"

uniform mat4 gbufferModelViewInverse;

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
    vertexColor = gl_Color;
    worldNormal = mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal);
    viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
}
