vec3 aureliaDebugLighting(vec3 normal, vec2 lightLevel) {
    return vec3(0.5 + 0.5 * normalize(normal).y, lightLevel.y, lightLevel.x);
}

vec3 aureliaDebugAdaptive(float smoothedFrameTime, float quality) {
    // R = pressure (30 ms -> 1), G = quality, B = neutral 50 FPS reference.
    float pressure = smoothstep(0.020, 0.033333, smoothedFrameTime);
    return vec3(pressure, quality, 0.40);
}

vec3 aureliaDebugShadowBudget(float samples) {
    // R=cheap one-tap state, G=Balanced four-tap state, B=nine-tap state.
    if (samples < 2.0) return vec3(0.92, 0.20, 0.14);
    if (samples < 6.0) return vec3(0.94, 0.72, 0.16);
    return vec3(0.20, 0.78, 0.34);
}
