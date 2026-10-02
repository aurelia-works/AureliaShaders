#version 330 compatibility

// Weather vertex stage. Weather quads are a screen-facing translucent overlay;
// no normals, no lightmap and no shadow varyings (the gbuffers_textured_lit
// fallback this pack used to fall into lit them like terrain).
//
// Fog is evaluated HERE, per vertex, instead of per pixel. Rain covers a large
// share of the screen with overlapping quads, so every fragment-stage ALU op is
// multiplied by the overdraw; and the fog blend is linear in the scene colour
// (mix(c, fog, f) = c * (1 - f) + fog * f), so two vertex-stage evaluations of
// the shared fog contract - one on black, one on white - give an offset and a
// keep factor the fragment stage applies with a single multiply-add. Quads are
// a few blocks tall at most, so the linear interpolation is exact enough.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

out vec2 texcoord;
out vec4 vertexColor;
out vec4 fogTerms;   // rgb: fog contribution, a: surviving fraction of the scene colour

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vertexColor = aureliaDecodeVertexColor(gl_Color);
    aureliaWriteFrameConstants();

    // World-axes, camera-relative: the fog colour is direction-dependent (the
    // dome's horizon/zenith and sun azimuth), so a view-space vector would tilt
    // it with camera pitch and yaw.
    vec3 viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vec3 playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    vec3 fogOnBlack = aureliaApplyFogContract(vec3(0.0), playerPosition, AURELIA_FOG_DENSITY, rainStrength);
    vec3 fogOnWhite = aureliaApplyFogContract(vec3(1.0), playerPosition, AURELIA_FOG_DENSITY, rainStrength);
    // white - black = (1 - f): the share of the scene colour that survives.
    fogTerms = vec4(fogOnBlack, fogOnWhite.g - fogOnBlack.g);
}
