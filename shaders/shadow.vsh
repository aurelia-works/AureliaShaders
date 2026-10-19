#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/shadow_distort.glsl"
#include "/lib/waving.glsl"

#ifdef AURELIA_WAVING
uniform mat4 shadowModelViewInverse;
uniform float rainStrength;
#endif

in vec4 mc_Entity;

out vec2 texcoord;

void main() {
    // Iris supplies the shadow camera matrices for this legacy 1.7.x program.
    // The projection is orthographic (w == 1), so clip xy is shadow NDC. The
    // receiver in lib/shadows.glsl applies the identical remap.
    // Plants (block.properties 10001/10003/10004) cast no shadow: collapse the
    // whole quad to one point outside the map so it rasterises nothing.
    int blockId = int(mc_Entity.x + 0.5);
    if (aureliaIsPlant(blockId)) {
        gl_Position = vec4(-2.0, -2.0, -2.0, 1.0);
        texcoord = vec2(0.0);
        return;
    }
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
#ifdef AURELIA_WAVING
    // Leaves sway in the main pass, so their casters must sway identically.
    // shadowModelView consumes player space, so its inverse recovers the
    // vertex's player position from the shadow camera's view position.
    vec3 playerPosition = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;
    vec3 wave = aureliaWaveOffset(blockId, texcoord, playerPosition + cameraPosition, rainStrength);
    gl_Position += gl_ModelViewProjectionMatrix * vec4(wave, 0.0);
#endif
    gl_Position.xy /= aureliaShadowDistortScale(gl_Position.xy);
}
