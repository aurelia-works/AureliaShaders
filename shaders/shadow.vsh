#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/shadow_distort.glsl"

in vec4 mc_Entity;

out vec2 texcoord;

void main() {
    // Iris supplies the shadow camera matrices for this legacy 1.7.x program.
    // The projection is orthographic (w == 1), so clip xy is shadow NDC. The
    // receiver in lib/shadows.glsl applies the identical remap.
    // Short plants (block.properties 10001) cast no shadow: collapse the
    // whole quad to one point outside the map so it rasterises nothing.
    if (int(mc_Entity.x + 0.5) == 10001) {
        gl_Position = vec4(-2.0, -2.0, -2.0, 1.0);
        texcoord = vec2(0.0);
        return;
    }
    gl_Position = ftransform();
    gl_Position.xy /= aureliaShadowDistortScale(gl_Position.xy);
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}
