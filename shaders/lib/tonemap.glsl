vec3 aureliaAcesFitted(vec3 color) {
    // Fitted filmic curve: restrained highlight rolloff without a bloom pass.
    //
    // GLSL's mat3 constructor fills COLUMNS. The canonical ACES fit is written
    // row-major, so listing those values directly built the TRANSPOSED matrix:
    // the curve hue-shifted clipped warm colours into salmon-pink (out.r clips
    // to 1.0 while out.b stays high), which is the pink sun this pack used to
    // render. The matrices below are the canonical ones, transposed for GLSL's
    // column-major constructor, so a neutral input stays neutral.
    const mat3 inputMat = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777
    );
    const mat3 outputMat = mat3(
         1.60475, -0.10208, -0.00327,
        -0.53108,  1.10813, -0.07276,
        -0.07367, -0.00605,  1.07602
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
