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
    // Exposure is part of the Look Contract; 1.00 is the identity baseline.
    color = aureliaAcesFitted(max(color, 0.0) * AURELIA_EXPOSURE);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, AURELIA_SKY_SATURATION);
    // Unbound-style micro-contrast about mid-grey. Identity at 1.00.
    color = (color - 0.5) * AURELIA_CONTRAST + 0.5;
    // Grey axis stays neutral: no split-toning. Complementary-style reference
    // keeps whites/greys on-axis and gets warmth only from light colors.
    return clamp(color, 0.0, 1.0);
}
