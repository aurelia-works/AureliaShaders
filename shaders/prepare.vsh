#version 330 compatibility

// Fullscreen pass over the sky-view LUT (colortex5, 128x129): Iris sets the
// viewport to the target's absolute size. See prepare.fsh.

void main() {
    gl_Position = ftransform();
}
