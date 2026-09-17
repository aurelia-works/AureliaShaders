#version 330 compatibility

out vec4 vertexColor;

void main() {
    gl_Position = ftransform();
    vertexColor = gl_Color;
}
