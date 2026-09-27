#!/usr/bin/env python3
"""Render Aurelia shaderpack previews offline, with no Minecraft and no window.

    tools/.venv/bin/python tools/preview.py --profile BALANCED
    tools/.venv/bin/python tools/preview.py --all-profiles --out preview/
    tools/.venv/bin/python tools/preview.py --time 0.5 --rain 0.8 --underwater

This executes the real programs from ``shaders/`` -- includes resolved, Iris
compatibility builtins shimmed in memory -- against a procedural scene on the
Mac's GPU, then writes PNGs. See docs/PREVIEW.md for what this does and does not
prove.
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

from preview_glsl import ProfileError, parse_profile  # noqa: E402
from preview_render import Camera, PreviewRenderer, Sky  # noqa: E402
from preview_scene import SEA_LEVEL, load_scene  # noqa: E402

PROFILES = ("POTATO", "LOW", "BALANCED", "CINEMATIC", "ADAPTIVE")


def presets(shaders_root: Path, profile: str) -> tuple[dict[str, str], set[str]]:
    """Numeric overrides plus the boolean options a preset switches off.

    ``parse_profile`` returns the booleans a preset enables; the complementary
    set of known booleans is what it disables.
    """
    from validate_shaderpack import BOOLEAN_OPTION

    overrides, enabled = parse_profile(shaders_root, profile)
    known = _known_booleans(shaders_root)
    return overrides, known - enabled


def _known_booleans(shaders_root: Path) -> set[str]:
    """The boolean options Iris actually exposes for this pack.

    Derived by set difference: every ``AURELIA_*`` name the pack mentions in
    ``shaders.properties``, minus the ones ``lib/options.glsl`` gives a value.
    Scanning the define lines directly instead would pick up internal derived
    macros such as ``AURELIA_ADAPTIVE_ENABLED``, which is defined twice inside
    an ``#ifdef`` and must never be undefined on its own.
    """
    from validate_shaderpack import OPTION

    value_options = {
        match.group(1)
        for match in (
            OPTION.match(line)
            for line in (shaders_root / "lib/options.glsl").read_text(encoding="utf-8").splitlines()
        )
        if match
    }
    properties = (shaders_root / "shaders.properties").read_text(encoding="utf-8")
    mentioned = set(re.findall(r"\bAURELIA_[A-Z_]+\b", properties))
    return mentioned - value_options


def camera_for(preset: str, time_of_day: float, underwater: bool) -> Camera:
    """A camera that frames the island, or sits under the water for a swim shot."""
    if underwater:
        return Camera(eye=(14.0, SEA_LEVEL - 3.0, 26.0), yaw=np.pi * 0.25, pitch=0.12, fov=75.0)
    if preset == "underwater":
        return Camera(eye=(14.0, SEA_LEVEL - 3.0, 26.0), yaw=np.pi * 0.25, pitch=0.12, fov=75.0)
    return Camera()


def write_png(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(image[:, :, :3], mode="RGB").save(path)


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    shaders_root = (root / "shaders").resolve()

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default="BALANCED", choices=PROFILES)
    parser.add_argument("--all-profiles", action="store_true", help="render every preset")
    parser.add_argument("--time", type=float, default=0.28, help="time of day, 0.25 is noon")
    parser.add_argument("--rain", type=float, default=0.0, help="rainStrength 0..1")
    parser.add_argument("--underwater", action="store_true", help="place the camera below the surface")
    parser.add_argument("--debug", type=int, default=None, help="override AURELIA_DEBUG_VIEW")
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--atlas-seed", type=int, default=7)
    parser.add_argument("--out", type=Path, default=root / "preview")
    parser.add_argument("--no-sky", action="store_true", help="skip the sky passes")
    parser.add_argument(
        "--bench",
        type=int,
        default=0,
        metavar="N",
        help="render N extra frames and report the mean, for a rough cost signal",
    )
    args = parser.parse_args(argv)

    print(f"building scene (seed {args.seed}) ...", flush=True)
    atlas, world, batches = load_scene(seed=args.seed, atlas_seed=args.atlas_seed)
    for name, batch in batches.items():
        print(f"  {name:8s} {batch.count:7d} triangles")

    targets = list(PROFILES) if args.all_profiles else [args.profile]
    written: list[Path] = []
    try:
        for preset in targets:
            try:
                overrides, undefined = presets(shaders_root, preset)
            except ProfileError as error:
                print(f"ERROR: {error}", file=sys.stderr)
                return 1
            if args.debug is not None:
                overrides["AURELIA_DEBUG_VIEW"] = str(args.debug)

            renderer = PreviewRenderer(
                shaders_root,
                width=args.width,
                height=args.height,
                overrides=overrides,
                undefined=undefined,
            )
            try:
                sky = Sky(time=args.time, rain=args.rain)
                camera = camera_for(preset, args.time, args.underwater)
                image, stats = renderer.render(
                    batches, atlas, camera, sky, draw_sky=not args.no_sky
                )
                suffix = "-underwater" if args.underwater else ""
                # The debug view belongs in the name: debug 0 and debug 5 produce
                # very different images of the same frame, and overwriting one
                # filename hides exactly the comparison you rendered it for.
                view = "normal" if args.debug in (None, 0) else f"debug{args.debug}"
                name = f"{preset.lower()}-{view}{suffix}-t{args.time:g}.png"
                path = args.out / name
                write_png(path, image)
                written.append(path)

                extra = ""
                if args.bench:
                    samples = []
                    for _ in range(args.bench):
                        start = time.perf_counter()
                        renderer.render(batches, atlas, camera, sky, draw_sky=not args.no_sky)
                        samples.append((time.perf_counter() - start) * 1000.0)
                    extra = f"  mean {np.mean(samples):6.2f} ms over {args.bench} frames"
                print(
                    f"  {preset:9s} shadows={'on' if stats['shadow'] else 'off':3s} "
                    f"map={int(stats['shadow_resolution']):4d}  frame {stats['frame_ms']:6.2f} ms{extra}"
                )
                _describe(image)
            finally:
                renderer.close()
    finally:
        pass

    for path in written:
        print(f"wrote {path.relative_to(root) if path.is_relative_to(root) else path}")
    return 0


def _describe(image: np.ndarray) -> None:
    """Cheap sanity read on the output: is anything actually in frame?"""
    rgb = image[:, :, :3].astype(np.float32) / 255.0
    luma = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    mean = float(luma.mean())
    black = float((luma < 0.02).mean())
    print(
        f"            luma mean {mean:.3f}  p95 {float(np.percentile(luma, 95)):.3f}  "
        f"near-black {black * 100:.1f}%"
    )
    if black > 0.92:
        print("            WARNING: frame is almost entirely black")


if __name__ == "__main__":
    raise SystemExit(main())
