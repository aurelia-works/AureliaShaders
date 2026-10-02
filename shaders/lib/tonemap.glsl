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

// Look-grade constants. Everything here is a fixed, deliberately small nudge;
// the user-facing knobs (exposure, saturation, contrast) stay identity at 1.00.
const vec3  AURELIA_GRADE_WARM_HIGHLIGHT = vec3(1.045, 1.000, 0.935); // linear gain at white
const vec3  AURELIA_GRADE_COOL_SHADOW    = vec3(0.0004, 0.0006, 0.0013); // linear lift at black
const float AURELIA_GRADE_VIBRANCE       = 0.12; // extra saturation for dull colours only (0.22 pushed sunlit foliage neon in game)
const float AURELIA_GRADE_CONTRAST_PIVOT = 0.46; // sRGB-encoded mid grey

// Returns the DISPLAY-ENCODED (sRGB) graded colour, ready for the 8-bit
// framebuffer. Contrast runs after encoding because its 0.5 pivot is only a
// mid-grey in a perceptual space: in display-linear 0.5 is sRGB 0.735, so the
// old pivot made contrast > 1 simply darken almost the whole image.
vec3 aureliaGrade(vec3 color) {
    // Exposure is part of the Look Contract; 1.00 is the identity baseline.
    color = aureliaAcesFitted(max(color, 0.0) * AURELIA_EXPOSURE);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    // Saturation about luma. Identity at 1.00; >1 can push a channel out of
    // range, which the encode clamps.
    color = mix(vec3(luma), color, AURELIA_SKY_SATURATION);
    // Vibrance: lift weakly-saturated colours more than strong ones, so the
    // muted haze and foliage of the scene gains richness without neon greens.
    float chroma = max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
    color = mix(vec3(luma), color, 1.0 + AURELIA_GRADE_VIBRANCE * (1.0 - clamp(chroma * 2.0, 0.0, 1.0)));
    // Gentle split tone: warm gain that only reaches the highlights, and a
    // cool lift that only reaches the shadows. Mid-greys stay near neutral.
    float hi = luma * luma;
    float lo = 1.0 - smoothstep(0.0, 0.25, luma);
    color = color * mix(vec3(1.0), AURELIA_GRADE_WARM_HIGHLIGHT, hi)
          + AURELIA_GRADE_COOL_SHADOW * lo;
    vec3 display = aureliaLinearToSrgb(color);
    return clamp((display - AURELIA_GRADE_CONTRAST_PIVOT) * AURELIA_CONTRAST
                 + AURELIA_GRADE_CONTRAST_PIVOT, 0.0, 1.0);
}
