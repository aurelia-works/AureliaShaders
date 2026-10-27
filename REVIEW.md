# Review rules (Aurelia Shaders)

Start every review with one line: `N issues` or `No issues.`

Every finding cites `path:line` and says what goes wrong, with the input or world state that triggers it. A finding without a file and line is dropped.

## Real failures here
- GLSL that Apple tile GPUs or Iris reject, or that uses something the README rules out (temporal history, compute, alpha test on `gbuffers_terrain_solid`).
- 8-bit banding back in the final pass (`shaders/final.fsh`, `shaders/lib/tonemap.glsl`), guarded by `tools/test_grade_banding.py`.
- A uniform or option used by a shader but not declared, or declared but unused (`tools/validate_shaderpack.py` checks this).
- A sky, nether, rain, water or cloud change that breaks a regression in `tools/test_*.py`.
- Preview output (`tools/preview*.py`) that shows a look the shader does not produce.
- A test edited or weakened so it passes.

## Ignore
- Style, naming and comment wording.
- Preview pixel differences inside the test tolerance.
- `tools/.venv` and generated zips.
- Suggestions that expand the change beyond its goal (list them as follow-ups).
