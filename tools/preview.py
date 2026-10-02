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
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

from preview_glsl import ProfileError, parse_profile  # noqa: E402
from preview_render import Camera, PreviewRenderer, Sky  # noqa: E402
from preview_scene import load_scene  # noqa: E402

PROFILES = ("POTATO", "LOW", "BALANCED", "CINEMATIC", "ADAPTIVE")


def presets(shaders_root: Path, profile: str) -> tuple[dict[str, str], set[str]]:
    """Numeric overrides plus the boolean options a preset switches off.

    ``parse_profile`` returns the booleans a preset enables; the complementary
    set of the boolean options Iris exposes for the pack is what it disables.
    """
    from validate_shaderpack import read_options

    overrides, enabled = parse_profile(shaders_root, profile)
    return overrides, set(read_options(shaders_root).booleans) - enabled


def camera_for(name: str) -> Camera:
    """Named viewpoints.

    One fixed camera cannot judge a whole look: Fresnel only shows at grazing
    angles, so water needs a camera down near the surface, and foliage needs one
    level with the canopy. These are chosen to make each feature visible rather
    than to be flattering.
    """
    presets = {
        # Outside and above the island, looking across the plateau: terrain,
        # trees, water and sky together. The establishing frame.
        "overview": Camera(eye=(-46.0, 31.0, -46.0), yaw=np.pi * 0.25, pitch=-0.10, fov=70.0),
        # Eye 1.6 blocks above the waterline, looking almost flat along it. The
        # water recedes to the horizon, so this is where Fresnel and the glint
        # path are actually exercised rather than viewed from straight above.
        "shore": Camera(eye=(-30.0, 16.5, -52.0), yaw=0.54, pitch=0.02, fov=68.0),
        # Standing on the plateau at canopy height, so leaf sides and undersides
        # are visible instead of being hidden by a top-down angle.
        "canopy": Camera(eye=(-26.0, 27.0, -26.0), yaw=np.pi * 0.25, pitch=0.02, fov=72.0),
        # Close on the glowstone pillar. The block-light term and any emissive
        # path need a short-range frame to be judged in.
        "glow": Camera(eye=(-12.0, 28.0, -2.0), yaw=0.0, pitch=-0.10, fov=60.0),
        # Sky, pointed at the sun for the given default time (0.28 puts it near
        # the zenith, so this looks up and forward). A flat sky is otherwise easy
        # to miss: it is roughly a third of a normal gameplay frame.
        "sky": Camera(eye=(0.0, 24.0, 0.0), yaw=0.29, pitch=0.64, fov=75.0),
        # Level with the sun but off to one side, so the gradient across the sky
        # is visible without the disc dominating it.
        "skyside": Camera(eye=(0.0, 24.0, 0.0), yaw=1.35, pitch=0.30, fov=75.0),
        # Below the surface, looking back up at the underside of the water.
        "underwater": Camera(eye=(0.0, 12.0, -30.0), yaw=0.0, pitch=0.10, fov=75.0),
        # Submerged viewpoints for the underwater atmosphere. Kept out of the
        # default CAMERAS contact sheet on purpose: adding them there would
        # change every existing sheet. Select one explicitly with
        # `--camera X --underwater-eye`. Eyes sit over open water (seabed height
        # <= 3), not inside a terrain column, and look toward the island.
        "underwater_shallow": Camera(eye=(0.0, 13.4, -40.0), yaw=0.0, pitch=0.05, fov=75.0),
        "underwater_medium": Camera(eye=(0.0, 9.5, -40.0), yaw=0.0, pitch=0.03, fov=75.0),
        "underwater_deep": Camera(eye=(-42.0, -4.0, -42.0), yaw=np.pi * 0.25, pitch=0.06, fov=75.0),
        "underwater_up": Camera(eye=(0.0, 9.5, -40.0), yaw=0.0, pitch=0.75, fov=75.0),
        "underwater_down": Camera(eye=(0.0, 9.5, -40.0), yaw=0.0, pitch=-0.55, fov=75.0),
        # Aimed at the sun for low-sun times (yaw/pitch match the sun's
        # azimuth/elevation at t≈0.03), so the disc and aureole are judgeable
        # by day instead of only at dusk.
        "sunview": Camera(eye=(0.0, 24.0, 0.0), yaw=-2.85, pitch=0.38, fov=75.0),
        # Aimed near the zenith, where the midnight moon sits (t=0.75 puts the
        # moon exactly overhead), so the night disc can actually be scored.
        "nightsky": Camera(eye=(0.0, 24.0, 0.0), yaw=0.30, pitch=1.00, fov=75.0),
        # High above the island, looking down at TERRAIN (which writes depth,
        # unlike the synthetic water): the elevated-camera state that
        # exercises the distant-rain helper's altitude gate.
        "skydive": Camera(eye=(0.0, 95.0, 0.0), yaw=0.30, pitch=-0.85, fov=75.0),
        # Mid-altitude for the fade band (+40ish over the plateau).
        "balcony": Camera(eye=(0.0, 62.0, -18.0), yaw=0.30, pitch=-0.55, fov=75.0),
    }
    if name not in presets:
        raise ValueError(f"unknown camera {name!r}; choose from {', '.join(sorted(presets))}")
    return presets[name]


CAMERAS = ("overview", "shore", "canopy", "glow", "sky", "skyside", "underwater", "sunview", "nightsky", "skydive", "balcony")

# Extra views that are selectable but never part of the default contact sheet.
UNDERWATER_CAMERAS = (
    "underwater_shallow",
    "underwater_medium",
    "underwater_deep",
    "underwater_up",
    "underwater_down",
)


def write_png(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(image[:, :, :3], mode="RGB").save(path)


def output_filename(preset: str, view: str, name: str, time: float, rain: float) -> str:
    """Deterministic CLI output name for one per-camera frame or contact sheet.

    Dry renders (``rain == 0``, the default) keep the legacy name so existing
    evidence stays byte-for-byte reproducible. Any rainy render appends
    ``-rain<value>`` so it can never silently overwrite the dry frame in the
    same ``--out`` directory (``:g`` formatting keeps it deterministic).
    """
    suffix = "" if rain == 0 else f"-rain{rain:g}"
    return f"{preset.lower()}-{view}-{name}-t{time:g}{suffix}.png"


def contact_sheet(tiles: list[tuple[str, np.ndarray]], columns: int = 2, gap: int = 4) -> np.ndarray:
    """Tile several renders into one labelled image.

    Judging a look from a single viewpoint hides the features that need a
    specific angle, so the default output is a sheet of viewpoints instead of
    one frame.
    """
    if not tiles:
        raise ValueError("no tiles to compose")
    height, width = tiles[0][1].shape[:2]
    rows = (len(tiles) + columns - 1) // columns
    sheet = np.zeros(((height + gap) * rows + gap, (width + gap) * columns + gap, 3), np.uint8)
    for index, (_, tile) in enumerate(tiles):
        row, column = divmod(index, columns)
        y = gap + row * (height + gap)
        x = gap + column * (width + gap)
        sheet[y:y + height, x:x + width] = tile[:, :, :3]
    return sheet


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    shaders_root = (root / "shaders").resolve()

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default="BALANCED", choices=PROFILES)
    parser.add_argument("--all-profiles", action="store_true", help="render every preset")
    parser.add_argument(
        "--camera",
        default=None,
        choices=CAMERAS + UNDERWATER_CAMERAS,
        help="viewpoint; default renders a contact sheet of every viewpoint",
    )
    parser.add_argument("--sheet-only", action="store_true", help="write only the contact sheet")
    parser.add_argument("--time", type=float, default=0.28, help="time of day, 0.25 is noon")
    parser.add_argument("--rain", type=float, default=0.0, help="rainStrength 0..1")
    parser.add_argument(
        "--frame-time",
        type=float,
        default=12.0,
        help="frameTimeCounter in continuous seconds; default 12.0 matches existing evidence",
    )
    parser.add_argument("--underwater", action="store_true", help="deprecated alias for --camera underwater")
    parser.add_argument(
        "--underwater-eye",
        action="store_true",
        help=(
            "set Iris isEyeInWater to 1 (camera submerged in water). Independent "
            "of --camera/--underwater so existing evidence, which does not set it, "
            "stays byte-for-byte reproducible"
        ),
    )
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
    # No --camera means render every viewpoint and compose a contact sheet, so a
    # look change is judged against all of them rather than one flattering angle.
    viewpoints = [args.camera] if args.camera else list(CAMERAS)
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
                frame_time=args.frame_time,
                underwater_eye=args.underwater_eye,
            )
            try:
                sky = Sky(time=args.time, rain=args.rain)
                # Follow the real framebuffer: the context may not have been
                # granted the requested size, and rendering at a different
                # resolution beats failing.
                size = f" {renderer.width}x{renderer.height}"
                tiles: list[tuple[str, np.ndarray]] = []
                last_stats = {}
                for viewpoint in viewpoints:
                    camera = camera_for(viewpoint)
                    image, last_stats = renderer.render(
                        batches, atlas, camera, sky, draw_sky=not args.no_sky
                    )
                    tiles.append((viewpoint, image))
                    if args.sheet_only:
                        continue
                    # The debug view and the viewpoint both belong in the name:
                    # overwriting one filename hides exactly the comparison you
                    # rendered it for. Rain too: see output_filename.
                    view = "normal" if args.debug in (None, 0) else f"debug{args.debug}"
                    path = args.out / output_filename(preset, view, viewpoint, args.time, args.rain)
                    write_png(path, image)
                    written.append(path)

                if len(tiles) > 1 or args.sheet_only:
                    # Always compose when asked, including for a single tile:
                    # otherwise --camera X --sheet-only wrote no file at all.
                    columns = 2 if len(tiles) > 2 else len(tiles)
                    sheet = contact_sheet(tiles, columns=columns)
                    view = "normal" if args.debug in (None, 0) else f"debug{args.debug}"
                    path = args.out / output_filename(preset, view, "sheet", args.time, args.rain)
                    write_png(path, sheet)
                    written.append(path)
                    print(f"  contact sheet: {' | '.join(name for name, _ in tiles)}")

                extra = ""
                if args.bench:
                    samples = []
                    for _ in range(args.bench):
                        start = time.perf_counter()
                        renderer.render(batches, atlas, camera_for(viewpoints[0]), sky, draw_sky=not args.no_sky)
                        samples.append((time.perf_counter() - start) * 1000.0)
                    extra = f"  mean {np.mean(samples):6.2f} ms over {args.bench} frames"
                print(
                    f"  {preset:9s}{size} shadows={'on' if last_stats['shadow'] else 'off':3s} "
                    f"map={int(last_stats['shadow_resolution']):4d}  frame {last_stats['frame_ms']:6.2f} ms{extra}"
                )
                for name, tile in tiles:
                    print(f"    {name}")
                    _describe(tile)
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
