#version 330 compatibility

// The analytical sky needs the direction this fragment is being drawn for.
// The fragment stage no longer consumes a geometry-derived direction: Minecraft
// rotates the sky dome by the celestial angle but draws the void plane
// unrotated, so geometry-based directions disagreed with each other and with
// sunPosition. See gbuffers_skybasic.fsh for the screen-space reconstruction
// this vertex stage feeds.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

out vec4 vertexColor;

void main() {
    gl_Position = ftransform();
    vertexColor = gl_Color;
    aureliaWriteFrameConstants();
}
