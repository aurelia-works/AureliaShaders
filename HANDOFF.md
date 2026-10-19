# Handoff — AureliaShaders Phase 5 (2026-10-19)

## Done (branch `perf/luxium-parity`, Phase 5 commit on top of e44e2a9)
- Phase 5 realism pass, see `docs/PHASE5.md`:
  - physical sky LUT (`prepare`) and sky irradiance (`prepare1`);
  - GGX BRDF and block-ID materials;
  - deferred SSR with mip-blurred roughness;
  - water as a medium;
  - auto exposure and Purkinje;
  - LUT haze;
  - cloud layer in deferred.
- In-game fix: gbuffers programs read the block atlas (atlas tiles on all water and sky).
  - Cause: Iris 1.7.6 binds only colortex4+ outside fullscreen passes (`IrisSamplers.addRenderTargetSamplers`).
  - Sky LUT moved colortex3 → colortex5; opaque copy colortex2 → colortex6.
  - `validate_shaderpack.py` now rejects gbuffers/shadow reads of colortex0-3.
- Verified in game (ClaudeShader, Balanced): lake at 101 63 57 shows its bed and reflections; open sky at 21 94 -248 is clean.

## State
- `python3 tools/validate_shaderpack.py`: PASS, 115 combinations.
- All 14 `tools/test_*.py`: PASS (run with `tools/.venv/bin/python`).
- ClaudeShader: `AureliaShaders-Phase5.zip` installed and selected. Player left in creative mode.

## Next
1. Rest of the in-game checklist (end of `docs/PHASE5.md`):
   - SSR on polished stone in a city street;
   - sunset;
   - rain on road and lawn;
   - night;
   - underwater Snell's window;
   - Nether/End;
   - F3 frame time in a busy district.
2. Merge to main / release zip when Jah says.
3. Optional:
   - `program.deferred` off for Potato;
   - IDs for common modded (MTR, Create) blocks;
   - bluer below-horizon haze.

## Known gaps
- Underwater light depth uses sky light level; terrain under leaves seen from under water is tinted slightly.
- The offline preview does not model Iris's colortex4+ gbuffers rule; the validator check covers it.
- Never stage `.workbuddy-ai/` (another tool's memory).

## Resume
```
cd "~/Downloads/PROJECTS/GITHUB REPOS/AureliaShaders"
python3 tools/validate_shaderpack.py && for t in tools/test_*.py; do tools/.venv/bin/python $t | tail -1; done
python3 tools/install_shaderpack.py --target "~/Library/Application Support/PrismLauncher/instances/ClaudeShader/minecraft/shaderpacks" --name AureliaShaders-Phase5.zip
```
