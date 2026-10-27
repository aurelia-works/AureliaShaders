Aurelia Shaders: a lightweight original Iris shaderpack for Minecraft Java 1.20.1, tuned for Apple Silicon laptops.

## Verification (before saying a task is done)
Run the checks below and paste their result lines (the build result, test counts, failures; not whole logs) in the final reply. A task is not done until they pass or each failure is named with its cause.
- Build: python3 tools/validate_shaderpack.py (needs glslangValidator on PATH, or pass --validator PATH)
- Test: for t in tools/test_*.py; do python3 "$t" || break; done (14 regression files, each runs as a script)
- Lint: validate_shaderpack.py covers the pack; no separate linter
- UI: yes (shader look). Read the preview render from `python3 tools/preview.py` (docs/PREVIEW.md) for each changed look; in-game checks need a real Iris install and Jah, so say not seen for in-game.

## Review and PRs
- Review rules: `REVIEW.md`. PR description: `.github/pull_request_template.md`.
- Before opening a PR, run `/code-review` on the branch diff. At most 3 review rounds; after that, re-scope and review only the diff added since the last round.

## Checks and CI
- Locally run only the test files for what you changed (`python3 tools/test_<area>.py`) plus `validate_shaderpack.py` when `shaders/` changed. CI (`.github/workflows/ci.yml`) runs the validator and the `tools/test_*.py` files that don't render (render tests need glfw and a GPU, so they stay local) on every PR and push to main.
- Don't launch Minecraft for shader checks; use `tools/preview.py`.
- One request = one branch = one PR titled `type(scope): what now works` (skill `ship`). Open the PR only when Jah asks.
