# Handoff — AureliaShaders Phase 5 (2026-10-19)

## Done
- `ebc356d`: Phase 5 realism pass, plus the Iris atlas fix (gbuffers read only colortex4+; sky LUT → colortex5, opaque copy → colortex6; validator guard).
- Next commit on `perf/luxium-parity`: in-game checklist fixes and the Potato speedup.
  - End: `aureliaNoSky()` = `hasCeiling || !hasSkylight` (lib/sky.glsl) gates sun, sky light, flare and god rays; `AURELIA_END_AMBIENT`.
  - Nether lava was cream. The no-sky EV floor was -6.4 and is now -4.0 (`AURELIA_EV_MIN_NO_SKY`). Ambient and fog are x5.28 and lava emission is 0.5.
  - Rain: water and glass sun glints fade with (1 - rain)^2.
  - Potato: `program.deferred.enabled = false` when SSR, the cloud layer and refraction are all off. The log confirms Iris skips it.
  - Results are written up in `docs/PHASE5.md` under "In-game results".

## In-game results (ClaudeShader, M1, 1080p, RD 8, town view)
- PASS: noon town and lake, sunset, rain, night, underwater, Nether, End, Potato.
- fps: vanilla 180-193 | Potato 67-79 | Low 45-62 | Balanced 39-46 | Complementary (Jah's low settings) 39-40.
- Not covered: SSR on polished stone. This world has no stone city.

## State
- Validator: PASS, 115 combinations. All 14 `tools/test_*.py`: PASS with `tools/.venv/bin/python`.
- ClaudeShader has the current tree installed. Pack options are restored to the original settings (DIRECT_LIGHT 1.05, SHADOW_ADAPTIVE off). Player in creative.

## Next
1. Merge to main, push and cut a release zip when Jah says.
2. Optional: IDs for MTR/Create blocks. Lava a touch more saturated (Soul Sand fog greys it).
3. Optional perf: the Balanced terrain pass (~5.8 ms offline) is the remaining cost, spread across features with no single hotspot.

## Known gaps
- The offline preview does not model Iris's colortex4+ rule. The validator covers it.
- Never stage `.workbuddy-ai/` (another tool's memory).

## Resume
```
cd "~/Downloads/PROJECTS/GITHUB REPOS/AureliaShaders"
python3 tools/validate_shaderpack.py && for t in tools/test_*.py; do tools/.venv/bin/python $t | tail -1; done
python3 tools/install_shaderpack.py --target "~/Library/Application Support/PrismLauncher/instances/ClaudeShader/minecraft/shaderpacks" --name AureliaShaders-Phase5.zip
```
