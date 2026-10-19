#version 330 compatibility

// 1x1 metering pass (colortex4); see composite.fsh.

void main() {
    gl_Position = ftransform();
}
