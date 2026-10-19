#version 330 compatibility

// Second pass over the sky-view LUT (colortex5, 128x129). See prepare1.fsh.

void main() {
    gl_Position = ftransform();
}
