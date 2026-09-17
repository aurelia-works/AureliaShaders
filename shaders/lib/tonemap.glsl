vec3 aureliaAcesFitted(vec3 color) {
    // Fitted filmic curve: restrained highlight rolloff without a bloom pass.
    const mat3 inputMat = mat3(
        0.59719, 0.35458, 0.04823,
        0.07600, 0.90834, 0.01566,
        0.02840, 0.13383, 0.83777
    );
    const mat3 outputMat = mat3(
        1.60475, -0.53108, -0.07367,
       -0.10208,  1.10813, -0.00605,
       -0.00327, -0.07276,  1.07602
    );
    color = inputMat * color;
    vec3 a = color * (color + 0.0245786) - 0.000090537;
    vec3 b = color * (0.983729 * color + 0.4329510) + 0.238081;
    return clamp(outputMat * (a / b), 0.0, 1.0);
}

vec3 aureliaGrade(vec3 color) {
    color = aureliaAcesFitted(max(color, 0.0));
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, AURELIA_SKY_SATURATION);
    // Very small split-toning: warmth is reserved for highlights; shadows stay cool.
    color += vec3(0.010, 0.004, -0.004) * smoothstep(0.45, 1.0, luma);
    color += vec3(-0.003, 0.001, 0.007) * (1.0 - smoothstep(0.05, 0.35, luma));
    return clamp(color, 0.0, 1.0);
}
