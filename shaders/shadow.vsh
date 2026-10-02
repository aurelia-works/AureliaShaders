#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/shadow_distort.glsl"

out vec2 texcoord;

void main() {
    // Iris supplies the shadow camera matrices for this legacy 1.7.x program.
    // The projection is orthographic (w == 1), so clip xy is shadow NDC. The
    // receiver in lib/shadows.glsl applies the identical remap.
    gl_Position = ftransform();
    gl_Position.xy /= aureliaShadowDistortScale(gl_Position.xy);
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}
