#!/usr/bin/env python3
"""Per-stage GPU timings for the pack's programs, offline, on the Mac's GPU.

    tools/.venv/bin/python tools/bench_gpu.py --profile BALANCED
    tools/.venv/bin/python tools/bench_gpu.py --all-profiles --width 2560 --height 1600
    tools/.venv/bin/python tools/bench_gpu.py --profile BALANCED --undef AURELIA_CLOUD_LAYER

Runs the preview harness's procedural scene and wraps each stage (shadow
casters, prepare passes, sky, terrain + water, deferred passes, clouds,
composite passes, final) in GL_TIME_ELAPSED queries. It
reports the median over --frames frames, so the numbers are GPU time only:
texture uploads, Python and the final readback are excluded.

What this is good for: A/B-ing a shader change's per-pixel and per-vertex cost
on the real Apple GPU. What it is not: an in-game FPS figure. Minecraft's own
CPU work, chunk meshing, entity and block-entity draws and Iris's draw-call
overhead are not here. ``--scene city`` measures the voxel city (towers, glass,
canal, street lamps), which is closer to Aurelia Metropolis than the island.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import preview_render  # noqa: E402
from OpenGL.GL import (  # noqa: E402
    GL_QUERY_RESULT,
    GL_TIME_ELAPSED,
    glBeginQuery,
    glDeleteQueries,
    glEndQuery,
    glFinish,
    glGenQueries,
    glGetQueryObjectuiv,
)
from preview import PROFILES, camera_for, preset_enabled, presets  # noqa: E402
from preview_render import Camera  # noqa: E402
from preview_render import PreviewRenderer, Sky  # noqa: E402
from preview_city import load_city  # noqa: E402
from preview_scene import load_scene  # noqa: E402

STAGES = ("shadow", "prepare", "sky", "terrain", "deferred", "clouds", "composite", "final")


def pass_stage(name: str) -> str:
    """The STAGES bucket of one fullscreen pass (prepare1 -> prepare)."""
    for stage in ("prepare", "deferred", "composite"):
        if name.startswith(stage):
            return stage
    return "final"


class StageTimer:
    """Accumulates GL_TIME_ELAPSED per stage for one frame.

    GL time queries cannot nest, so a wrapped call made while another is being
    timed (deferred passes inside the scene in --whole mode) is charged to the
    outer stage. ``stage`` may be a function of the wrapped call's first
    argument, which names the pass for ``_run_composite_pass``.
    """

    def __init__(self) -> None:
        self.pending: list[tuple[str, int]] = []
        self.active = False

    def wrap(self, stage, function):
        def timed(*args, **kwargs):
            if self.active:
                return function(*args, **kwargs)
            label = stage(args[0]) if callable(stage) else stage
            self.active = True
            query = int(np.ravel(glGenQueries(1))[0])
            glBeginQuery(GL_TIME_ELAPSED, query)
            try:
                return function(*args, **kwargs)
            finally:
                glEndQuery(GL_TIME_ELAPSED)
                self.active = False
                self.pending.append((label, query))

        return timed

    def collect(self) -> dict[str, float]:
        glFinish()
        totals = dict.fromkeys(STAGES, 0.0)
        for stage, query in self.pending:
            # 32-bit nanoseconds (PyOpenGL cannot map the 64-bit getter);
            # a stage would have to exceed 4 s to wrap.
            totals[stage] += float(glGetQueryObjectuiv(query, GL_QUERY_RESULT)) / 1.0e6
            glDeleteQueries(1, [query])
        self.pending.clear()
        return totals


def instrument(renderer: PreviewRenderer, timer: StageTimer, whole: bool) -> None:
    if whole:
        # One query around the whole frame. Per-stage queries can split the
        # GPU's render pass, which hides cross-draw effects such as Apple's
        # hidden-surface removal of sky fragments behind opaque terrain.
        renderer._render_scene = timer.wrap("terrain", renderer._render_scene)
        renderer._render_shadow = timer.wrap("shadow", renderer._render_shadow)
        renderer._run_composite_pass = timer.wrap(pass_stage, renderer._run_composite_pass)
        preview_render._read_pixels = lambda width, height: np.zeros((1, 1, 4), np.uint8)
        return
    renderer._render_shadow = timer.wrap("shadow", renderer._render_shadow)
    renderer._draw_sky = timer.wrap("sky", renderer._draw_sky)
    renderer._draw_geometry = timer.wrap("terrain", renderer._draw_geometry)
    renderer._draw_clouds = timer.wrap("clouds", renderer._draw_clouds)
    renderer._run_composite_pass = timer.wrap(pass_stage, renderer._run_composite_pass)
    # The display readback is a harness cost, not a shader cost.
    preview_render._read_pixels = lambda width, height: np.zeros((1, 1, 4), np.uint8)


def bench(shaders_root: Path, profile: str, args, batches, atlas) -> dict[str, float]:
    overrides, undefined = presets(shaders_root, profile)
    enabled = preset_enabled(shaders_root, profile)
    for item in args.define:
        name, _, value = item.partition("=")
        undefined.discard(name)
        if value:
            overrides[name] = value
        else:
            enabled.add(name)
    undefined.update(args.undef)
    enabled -= set(args.undef)
    renderer = PreviewRenderer(
        shaders_root, width=args.width, height=args.height,
        overrides=overrides, undefined=undefined, enabled=enabled,
    )
    try:
        timer = StageTimer()
        instrument(renderer, timer, args.whole)
        sky = Sky(time=args.time, rain=args.rain)
        if args.camera.count(",") == 4:
            # x,y,z,yaw,pitch for a one-off viewpoint (e.g. facing the sun).
            x, y, z, yaw, pitch = (float(v) for v in args.camera.split(","))
            camera = Camera(eye=(x, y, z), yaw=yaw, pitch=pitch, fov=70.0)
        else:
            camera = camera_for(args.camera)
        samples: list[dict[str, float]] = []
        for frame in range(args.warmup + args.frames):
            renderer.render(batches, atlas, camera, sky)
            totals = timer.collect()
            if frame >= args.warmup:
                samples.append(totals)
        return {stage: float(np.median([s[stage] for s in samples])) for stage in STAGES}
    finally:
        renderer.close()


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    shaders_root = root / "shaders"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default="BALANCED", choices=PROFILES)
    parser.add_argument("--all-profiles", action="store_true")
    parser.add_argument("--camera", default="overview")
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--frames", type=int, default=30)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--time", type=float, default=0.28)
    parser.add_argument("--rain", type=float, default=0.0)
    parser.add_argument("--define", action="append", default=[], metavar="NAME[=VALUE]")
    parser.add_argument("--undef", action="append", default=[], metavar="NAME")
    parser.add_argument("--whole", action="store_true", help="time the whole scene pass as one 'terrain' figure")
    parser.add_argument("--scene", choices=("island", "city"), default="island")
    parser.add_argument("--shaders", type=Path, default=shaders_root, help="shaders/ directory to measure (for A/B copies)")
    args = parser.parse_args(argv)
    shaders_root = args.shaders.resolve()

    atlas, _, batches = load_city() if args.scene == "city" else load_scene()
    if args.scene == "city" and args.camera == "overview":
        args.camera = "street"
    profiles = list(PROFILES) if args.all_profiles else [args.profile]
    print(f"{'profile':10s}" + "".join(f"{s:>10s}" for s in STAGES) + f"{'total':>9s}   (GPU ms, median of {args.frames}, {args.width}x{args.height})")
    for profile in profiles:
        result = bench(shaders_root, profile, args, batches, atlas)
        total = sum(result.values())
        print(f"{profile:10s}" + "".join(f"{result[s]:10.3f}" for s in STAGES) + f"{total:9.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
