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
// Phase 5 film response. A per-channel sigmoid in log2 exposure, the idea
// behind AgX: compress each channel over a fixed window of stops around mid
// grey, in a slightly desaturated ("inset") space so a very bright saturated
// light rolls to white along its own hue instead of clipping to a primary,
// then hand back part of the saturation ("outset"). The window is 10 stops
// under and 6.5 over 18% grey; the curve's mid point puts 18% at sRGB 0.46
// (display mid grey) and matches sRGB through the shadows, then gives five
// stops of shoulder above it. Output is display-encoded.
const float AURELIA_FILM_MIN_EV = -10.0;
const float AURELIA_FILM_MAX_EV = 6.5;
const float AURELIA_FILM_SLOPE  = 8.0;
const float AURELIA_FILM_CENTER = 0.6365;
const float AURELIA_FILM_FLOOR  = 0.0061082;   // the sigmoid at t = 0
const float AURELIA_FILM_SCALE  = 1.0614220;   // 1 / (sigmoid(1) - sigmoid(0))
const float AURELIA_FILM_INSET  = 0.14;
const float AURELIA_FILM_OUTSET = 1.12;

vec3 aureliaFilm(vec3 color) {
    const vec3 luma = vec3(0.2126, 0.7152, 0.0722);
    color = max(color, 0.0);
    color = mix(color, vec3(dot(color, luma)), AURELIA_FILM_INSET);
    vec3 t = (log2(max(color, 1e-10) / 0.18) - AURELIA_FILM_MIN_EV) / (AURELIA_FILM_MAX_EV - AURELIA_FILM_MIN_EV);
    t = clamp(t, 0.0, 1.0);
    vec3 display = (1.0 / (1.0 + exp(-AURELIA_FILM_SLOPE * (t - AURELIA_FILM_CENTER))) - AURELIA_FILM_FLOOR)
                 * AURELIA_FILM_SCALE;
    float mean = dot(display, luma);
    return clamp(mean + (display - mean) * AURELIA_FILM_OUTSET, 0.0, 1.0);
}

vec3 aureliaGrade(vec3 color) {
    vec3 display = aureliaFilm(color * AURELIA_EXPOSURE);
    float luma = dot(display, vec3(0.2126, 0.7152, 0.0722));
    display = mix(vec3(luma), display, AURELIA_SKY_SATURATION);
    return clamp((display - AURELIA_GRADE_CONTRAST_PIVOT) * AURELIA_CONTRAST
                 + AURELIA_GRADE_CONTRAST_PIVOT, 0.0, 1.0);
}
