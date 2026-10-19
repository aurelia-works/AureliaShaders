#!/usr/bin/env python3
"""A synthetic city block for the offline preview: canal, streets, towers.

The island scene (``preview_scene.py``) has no man-made materials, so it cannot
show what realism in a Minecraft city mostly is: glass, metal, concrete,
polished stone, wet asphalt, street lamps and a canal reflecting the buildings.
This module builds such a block from voxels, with Minecraft-style per-vertex
ambient occlusion and smooth sky/block light, and tags every block with the
``mc_Entity`` ID the pack's own ``block.properties`` gives it, so the material
code paths run exactly as they would in game.

Layout (x east, z south, y up; ground top at y = 64, as in Minecraft):

    z <= -22   low buildings          z = -6..6   canal, quays, water 1.1 below
    z -19..-13 road                   z 7..9      promenade with street lamps
    z -12..-7  park strip with trees  z 10..16    road, z 17..18 sidewalk
                                      z >= 20     towers: glass, brick, concrete,
                                                  metal-clad, quartz
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from preview_scene import (
    TINT_FOLIAGE,
    TINT_PLAINS,
    TINT_WATER,
    TINT_WHITE,
    Batch,
    _Builder,
    _value_noise,
    block_id,
)

TILE_PX = 32
ATLAS_COLS = 4
ATLAS_ROWS = 8
ATLAS_W = TILE_PX * ATLAS_COLS
ATLAS_H = TILE_PX * ATLAS_ROWS

GROUND = 64  # top surface of the street level
WATER_TOP = 62.875  # 14/16 of the top water cell, Minecraft's still-water height


# --------------------------------------------------------------------------- #
# Blocks
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Kind:
    name: str  # Minecraft block name, for the block.properties ID
    top: int  # atlas tile for up/down faces
    side: int  # atlas tile for walls
    layer: str = "opaque"  # opaque | cutout | translucent
    tint: tuple[float, float, float] = (1.0, 1.0, 1.0)
    side_tint: tuple[float, float, float] | None = None
    light: int = 0  # block light emitted (0..15)


(T_ASPHALT, T_SMOOTH, T_CONC_WHITE, T_CONC_GREY, T_GLASS, T_STAINED, T_IRON, T_ANDESITE,
 T_STONE_BRICK, T_QUARTZ, T_BRICK, T_LANTERN, T_GRASS, T_GRASS_SIDE, T_DIRT, T_LEAVES,
 T_LOG, T_WATER, T_GRAVEL, T_DARK_METAL, T_GOLD, T_COPPER, T_STAINED_DARK, T_CONC_DARK) = range(24)

KINDS: dict[int, Kind] = {}


def _kind(code: int, kind: Kind) -> int:
    KINDS[code] = kind
    return code


AIR = 0
ASPHALT = _kind(1, Kind("black_concrete", T_ASPHALT, T_ASPHALT))
LANE = _kind(2, Kind("white_concrete", T_CONC_WHITE, T_CONC_WHITE))
SIDEWALK = _kind(3, Kind("smooth_stone", T_SMOOTH, T_SMOOTH))
QUAY = _kind(4, Kind("polished_andesite", T_ANDESITE, T_ANDESITE))
STONE_BRICKS = _kind(5, Kind("stone_bricks", T_STONE_BRICK, T_STONE_BRICK))
GRAVEL = _kind(6, Kind("gravel", T_GRAVEL, T_GRAVEL))
WATER = _kind(7, Kind("water", T_WATER, T_WATER, "translucent", tuple(TINT_WATER)))
CONC_WHITE = _kind(8, Kind("white_concrete", T_CONC_WHITE, T_CONC_WHITE))
CONC_GREY = _kind(9, Kind("light_gray_concrete", T_CONC_GREY, T_CONC_GREY))
GLASS = _kind(10, Kind("glass", T_GLASS, T_GLASS, "cutout"))
STAINED = _kind(11, Kind("light_blue_stained_glass", T_STAINED, T_STAINED, "translucent"))
STAINED_DARK = _kind(12, Kind("black_stained_glass", T_STAINED_DARK, T_STAINED_DARK, "translucent"))
IRON = _kind(13, Kind("iron_block", T_IRON, T_IRON))
QUARTZ = _kind(14, Kind("quartz_block", T_QUARTZ, T_QUARTZ))
BRICKS = _kind(15, Kind("bricks", T_BRICK, T_BRICK))
LANTERN = _kind(16, Kind("sea_lantern", T_LANTERN, T_LANTERN, light=15))
GRASS = _kind(17, Kind("grass_block", T_GRASS, T_GRASS_SIDE, tint=tuple(TINT_PLAINS), side_tint=tuple(TINT_PLAINS)))
DIRT = _kind(18, Kind("dirt", T_DIRT, T_DIRT))
LEAVES = _kind(19, Kind("oak_leaves", T_LEAVES, T_LEAVES, "cutout", tuple(TINT_FOLIAGE)))
LOG = _kind(20, Kind("oak_log", T_DIRT, T_LOG))
DARK_METAL = _kind(21, Kind("netherite_block", T_DARK_METAL, T_DARK_METAL))
GOLD = _kind(22, Kind("gold_block", T_GOLD, T_GOLD))
COPPER = _kind(23, Kind("cut_copper", T_COPPER, T_COPPER))
CONC_DARK = _kind(24, Kind("gray_concrete", T_CONC_DARK, T_CONC_DARK))
INTERIOR = _kind(25, Kind("light_gray_concrete", T_CONC_GREY, T_CONC_GREY))


def _opaque(code: int) -> bool:
    return code != AIR and KINDS[code].layer == "opaque"


# --------------------------------------------------------------------------- #
# Atlas
# --------------------------------------------------------------------------- #


def build_city_atlas(seed: int = 5) -> np.ndarray:
    """RGBA sRGB atlas, uint8, ``ATLAS_H x ATLAS_W``. Plain procedural tiles
    close to the vanilla textures' value and colour, not their detail."""
    rng = np.random.default_rng(seed)
    n = TILE_PX
    fine = _value_noise(rng, n, 16)
    medium = _value_noise(rng, n, 8)
    coarse = _value_noise(rng, n, 4)
    grain = rng.random((n, n)).astype(np.float32)
    edge = np.zeros((n, n), bool)
    edge[[0, -1], :] = True
    edge[:, [0, -1]] = True

    def flat(rgb, noise, amount):
        return np.asarray(rgb, np.float32) * (1.0 - amount / 2 + amount * noise)[..., None]

    tiles: dict[int, np.ndarray] = {}
    tiles[T_ASPHALT] = flat([0.11, 0.11, 0.12], 0.6 * fine + 0.4 * grain, 0.30)
    smooth = flat([0.66, 0.66, 0.66], fine, 0.08)
    smooth[edge] *= 0.82
    tiles[T_SMOOTH] = smooth
    tiles[T_CONC_WHITE] = flat([0.81, 0.83, 0.84], fine, 0.05)
    tiles[T_CONC_GREY] = flat([0.49, 0.49, 0.45], fine, 0.06)
    tiles[T_CONC_DARK] = flat([0.21, 0.22, 0.24], fine, 0.06)
    glass = np.zeros((n, n, 4), np.float32)
    glass[..., :3] = 0.86
    frame = np.zeros((n, n), bool)
    frame[[0, 1, -2, -1], :] = True
    frame[:, [0, 1, -2, -1]] = True
    streak = (np.abs(np.subtract.outer(np.arange(n), np.arange(n)) - 9) < 1) & (np.arange(n)[None, :] > 6)
    glass[..., 3] = np.where(frame | streak, 1.0, 0.0)
    glass[frame, :3] = 0.80
    tiles[T_GLASS] = glass
    stained = np.zeros((n, n, 4), np.float32)
    stained[..., :3] = [0.40, 0.62, 0.82]
    stained[..., 3] = 0.42
    stained[frame, :3] = [0.32, 0.50, 0.70]
    stained[frame, 3] = 0.85
    tiles[T_STAINED] = stained
    dark = stained.copy()
    dark[..., :3] = [0.10, 0.11, 0.13]
    dark[..., 3] = 0.68
    dark[frame, 3] = 0.92
    tiles[T_STAINED_DARK] = dark
    iron = flat([0.80, 0.80, 0.80], medium, 0.10)
    iron[[0, 15, 16, 31], :] *= 0.80
    iron[:, [0, 31]] *= 0.80
    tiles[T_IRON] = iron
    tiles[T_ANDESITE] = flat([0.53, 0.54, 0.54], 0.5 * fine + 0.5 * grain, 0.16)
    bricks = flat([0.47, 0.47, 0.47], fine, 0.20)
    bricks[[0, 15, 16, 31], :] *= 0.65
    bricks[:16, [0, 31]] *= 0.65
    bricks[16:, [15, 16]] *= 0.65
    tiles[T_STONE_BRICK] = bricks
    tiles[T_QUARTZ] = flat([0.92, 0.89, 0.85], fine, 0.04)
    red = flat([0.58, 0.29, 0.23], fine, 0.22)
    seams = np.arange(n) % 8 == 0
    red[seams, :] = 0.70
    red[:, seams] = 0.70
    tiles[T_BRICK] = red
    lantern = flat([0.82, 0.93, 0.90], coarse, 0.20)
    lantern[edge] = [0.55, 0.70, 0.66]
    tiles[T_LANTERN] = lantern
    tiles[T_GRASS] = flat([0.88, 0.88, 0.88], medium, 0.36)
    dirt = flat([0.56, 0.42, 0.30], fine, 0.30)
    side = dirt.copy()
    side[:7] = tiles[T_GRASS][:7]
    tiles[T_GRASS_SIDE] = side
    tiles[T_DIRT] = dirt
    leaves = flat([0.82, 0.82, 0.82], fine, 0.52)
    tiles[T_LEAVES] = np.dstack([leaves, (fine > 0.40).astype(np.float32)])
    tiles[T_LOG] = flat([0.44, 0.33, 0.20], _value_noise(rng, n, 3), 0.38)
    tiles[T_WATER] = np.dstack([flat([0.22, 0.45, 0.82], coarse, 0.24), np.full((n, n), 0.72, np.float32)])
    tiles[T_GRAVEL] = flat([0.46, 0.44, 0.44], 0.5 * coarse + 0.5 * grain, 0.55)
    metal = flat([0.24, 0.23, 0.24], medium, 0.10)
    tiles[T_DARK_METAL] = metal
    gold = flat([0.98, 0.82, 0.30], medium, 0.14)
    gold[edge] *= 0.85
    tiles[T_GOLD] = gold
    copper = flat([0.76, 0.45, 0.33], medium, 0.18)
    copper[[0, 15, 16, 31], :] *= 0.80
    tiles[T_COPPER] = copper

    atlas = np.ones((ATLAS_H, ATLAS_W, 4), np.float32)
    for index, tile in tiles.items():
        cx, cy = index % ATLAS_COLS, index // ATLAS_COLS
        y0 = (ATLAS_ROWS - 1 - cy) * TILE_PX
        block = atlas[y0:y0 + TILE_PX, cx * TILE_PX:(cx + 1) * TILE_PX]
        block[:, :, :3] = tile[:, :, :3]
        block[:, :, 3] = tile[:, :, 3] if tile.shape[2] == 4 else 1.0
    return (np.clip(atlas, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def _tile_uvs(tile: int) -> tuple[tuple[float, float], ...]:
    cx, cy = tile % ATLAS_COLS, tile // ATLAS_COLS
    inset = 0.25
    u0 = (cx * TILE_PX + inset) / ATLAS_W
    u1 = ((cx + 1) * TILE_PX - inset) / ATLAS_W
    v1 = 1.0 - (cy * TILE_PX + inset) / ATLAS_H
    v0 = 1.0 - ((cy + 1) * TILE_PX - inset) / ATLAS_H
    return ((u0, v0), (u0, v1), (u1, v1), (u1, v0))


# --------------------------------------------------------------------------- #
# Voxel world
# --------------------------------------------------------------------------- #

X0, X1 = -60, 60
Y0, Y1 = 52, 112
Z0, Z1 = -48, 48


class Grid:
    def __init__(self) -> None:
        self.cells = np.zeros((X1 - X0, Y1 - Y0, Z1 - Z0), np.uint8)

    def box(self, code: int, x0, x1, y0, y1, z0, z1) -> None:
        """Fill the half-open box [x0, x1) x [y0, y1) x [z0, z1)."""
        self.cells[x0 - X0:x1 - X0, y0 - Y0:y1 - Y0, z0 - Z0:z1 - Z0] = code

    def set(self, code: int, x: int, y: int, z: int) -> None:
        self.cells[x - X0, y - Y0, z - Z0] = code


def _building(grid: Grid, x0, x1, z0, z1, height, wall, window, pattern, trim=None, roof=None) -> None:
    """A hollow building with floors every 4 blocks and a window pattern.

    ``pattern(x, y, z)`` is True where a wall cell is a window.
    """
    top = GROUND + height
    grid.box(wall, x0, x1, GROUND, top, z0, z1)
    grid.box(AIR, x0 + 1, x1 - 1, GROUND + 1, top - 1, z0 + 1, z1 - 1)
    for y in range(GROUND + 4, top - 1, 4):
        grid.box(INTERIOR, x0 + 1, x1 - 1, y, y + 1, z0 + 1, z1 - 1)
    for x in range(x0, x1):
        for z in (z0, z1 - 1):
            for y in range(GROUND + 1, top - 1):
                if pattern(x - x0, y - GROUND, x0 < x < x1 - 1):
                    grid.set(window, x, y, z)
    for z in range(z0 + 1, z1 - 1):
        for x in (x0, x1 - 1):
            for y in range(GROUND + 1, top - 1):
                if pattern(z - z0, y - GROUND, True):
                    grid.set(window, x, y, z)
    if trim is not None:
        grid.box(trim, x0, x1, top - 1, top, z0, z1)
    if roof is not None:
        grid.box(roof, x0, x1, top, top + 1, z0, z1)


def build_city_grid() -> Grid:
    grid = Grid()
    # Ground: stone under everything, gravel canal bed, water 4 deep.
    grid.box(STONE_BRICKS, X0, X1, Y0, GROUND, Z0, Z1)
    grid.box(GRAVEL, X0, X1, 56, 59, -5, 6)
    grid.box(WATER, X0, X1, 59, 63, -5, 6)
    grid.box(AIR, X0, X1, 63, Y1, -5, 6)
    # Surface layer (y = GROUND - 1) by z band.
    surface = GROUND - 1

    def band(code, z0, z1):
        grid.box(code, X0, X1, surface, GROUND, z0, z1)

    band(QUAY, 6, 7)
    band(QUAY, -6, -5)
    band(SIDEWALK, 7, 10)
    band(ASPHALT, 10, 17)
    band(SIDEWALK, 17, 20)
    band(SIDEWALK, 20, Z1)
    band(GRASS, -12, -6)
    grid.box(DIRT, X0, X1, surface - 2, surface, -12, -6)
    band(ASPHALT, -19, -12)
    band(SIDEWALK, -22, -19)
    band(SIDEWALK, Z0, -22)
    for x in range(X0, X1):
        if (x - X0) % 6 < 3:
            grid.set(LANE, x, surface, 13)
            grid.set(LANE, x, surface, -16)

    # Street lamps: dark metal posts, sea-lantern heads.
    for x in range(-54, 58, 12):
        for z in (8, -7):
            grid.box(DARK_METAL, x, x + 1, GROUND, GROUND + 4, z, z + 1)
            grid.set(LANTERN, x, GROUND + 4, z)
    # Park trees.
    for x in range(-52, 56, 12):
        z = -10
        grid.box(LOG, x, x + 1, GROUND, GROUND + 5, z, z + 1)
        grid.box(LEAVES, x - 2, x + 3, GROUND + 3, GROUND + 5, z - 2, z + 3)
        grid.box(LEAVES, x - 1, x + 2, GROUND + 5, GROUND + 7, z - 1, z + 2)
        grid.box(LOG, x, x + 1, GROUND, GROUND + 5, z, z + 1)

    # North towers.
    _building(grid, -50, -34, 21, 35, 40, CONC_WHITE, STAINED,
              lambda u, v, inner: inner and v % 4 != 0, roof=CONC_GREY)
    _building(grid, -30, -16, 21, 33, 18, BRICKS, GLASS,
              lambda u, v, inner: u % 3 == 1 and v % 4 in (1, 2))
    _building(grid, -12, 8, 21, 36, 26, CONC_WHITE, GLASS,
              lambda u, v, inner: inner and v % 4 in (1, 2), trim=QUARTZ)
    _building(grid, 12, 28, 21, 35, 32, IRON, STAINED_DARK,
              lambda u, v, inner: u % 3 != 0 and v % 4 != 0, roof=CONC_DARK)
    _building(grid, 32, 48, 21, 33, 14, QUARTZ, GLASS,
              lambda u, v, inner: inner and u % 4 in (1, 2) and v % 4 in (1, 2) and v > 3, roof=COPPER)
    grid.box(GOLD, 32, 48, GROUND, GROUND + 1, 21, 22)
    # South side, lower.
    _building(grid, -46, -26, -36, -23, 12, CONC_GREY, GLASS,
              lambda u, v, inner: inner and v % 4 in (1, 2))
    _building(grid, -22, 4, -36, -23, 16, BRICKS, GLASS,
              lambda u, v, inner: u % 3 == 1 and v % 4 in (1, 2))
    _building(grid, 8, 30, -36, -23, 10, CONC_WHITE, GLASS,
              lambda u, v, inner: inner and v % 4 in (1, 2), trim=QUARTZ)
    _building(grid, 34, 50, -36, -23, 22, CONC_DARK, STAINED,
              lambda u, v, inner: inner and v % 4 != 0)
    return grid


# --------------------------------------------------------------------------- #
# Light
# --------------------------------------------------------------------------- #


def _propagate(level: np.ndarray, passable: np.ndarray, steps: int = 15) -> np.ndarray:
    """Minecraft-style flood fill: each step a passable cell takes the
    brightest neighbour minus one."""
    for _ in range(steps):
        best = level.copy()
        for axis in range(3):
            for shift in (1, -1):
                rolled = np.roll(level, shift, axis=axis)
                # No wrap-around at the grid edges.
                edge = [slice(None)] * 3
                edge[axis] = 0 if shift == 1 else -1
                rolled[tuple(edge)] = 0
                best = np.maximum(best, rolled - 1)
        level = np.where(passable, np.maximum(level, best), level)
    return level


def compute_light(grid: Grid) -> tuple[np.ndarray, np.ndarray]:
    cells = grid.cells
    opaque_codes = np.array([code for code in KINDS if _opaque(code)], np.uint8)
    opaque = np.isin(cells, opaque_codes)
    passable = ~opaque
    # Sky light 15 straight down every column until the first opaque cell.
    blocked = np.cumsum(opaque[:, ::-1, :], axis=1)[:, ::-1, :] > 0
    sky = np.where(~blocked, 15, 0).astype(np.int16)
    # Water dims it by one per block on the way down.
    water = cells == WATER
    depth = np.cumsum(water[:, ::-1, :], axis=1)[:, ::-1, :]
    sky = np.where(water | (depth > 0), np.maximum(sky - depth, 0), sky)
    sky = _propagate(sky, passable)
    emitters = np.zeros_like(sky)
    for code, kind in KINDS.items():
        if kind.light:
            emitters[cells == code] = kind.light
    block = _propagate(emitters, passable | (emitters > 0))
    return sky, block


# --------------------------------------------------------------------------- #
# Meshing
# --------------------------------------------------------------------------- #

# (normal, corners in unit-cube coordinates), the same corner order as
# preview_scene._FACE_SIDES so the tile UVs land the same way up.
_FACES = (
    ((0, 1, 0), ((0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0))),
    ((0, -1, 0), ((0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1))),
    ((1, 0, 0), ((1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1))),
    ((-1, 0, 0), ((0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0))),
    ((0, 0, 1), ((0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1))),
    ((0, 0, -1), ((1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0))),
)


def _face_visible(code: int, neighbour: int) -> bool:
    if neighbour == AIR:
        return True
    if neighbour == code:
        return False
    if _opaque(neighbour):
        return False
    # A cutout or translucent neighbour: an opaque face behind it shows, and
    # two different see-through blocks show each other.
    return not (KINDS[code].layer == "translucent" and code == WATER)


def build_city_batches(grid: Grid) -> dict[str, Batch]:
    cells = grid.cells
    sky, block = compute_light(grid)
    shape = cells.shape
    builders = {"opaque": _Builder(), "cutout": _Builder(), "water": _Builder()}

    def at(array, i, j, k, default=0):
        if 0 <= i < shape[0] and 0 <= j < shape[1] and 0 <= k < shape[2]:
            return int(array[i, j, k])
        return default

    def solid(i, j, k) -> bool:
        return _opaque(at(cells, i, j, k))

    filled = np.argwhere(cells != AIR)
    for i, j, k in filled:
        code = int(cells[i, j, k])
        kind = KINDS[code]
        for normal, corners in _FACES:
            ni, nj, nk = i + normal[0], j + normal[1], k + normal[2]
            neighbour = at(cells, ni, nj, nk, AIR if nj >= shape[1] else STONE_BRICKS)
            if code == WATER and normal != (0, 1, 0):
                continue
            if not _face_visible(code, neighbour):
                continue
            axes = [a for a in range(3) if normal[a] == 0]
            positions, ao, light = [], [], []
            for corner in corners:
                position = [i + X0 + corner[0], j + Y0 + corner[1], k + Z0 + corner[2]]
                if code == WATER and normal == (0, 1, 0):
                    position[1] = WATER_TOP + (j + Y0 - 62)
                positions.append(position)
                s = [1 if corner[a] == 1 else -1 for a in axes]
                front = [ni, nj, nk]
                side1 = list(front)
                side1[axes[0]] += s[0]
                side2 = list(front)
                side2[axes[1]] += s[1]
                diag = list(side1)
                diag[axes[1]] += s[1]
                o1, o2, oc = solid(*side1), solid(*side2), solid(*diag)
                level = 0 if (o1 and o2) else 3 - int(o1) - int(o2) - int(oc)
                ao.append(0.40 + 0.60 * level / 3.0)
                sky_sum = block_sum = count = 0
                for cell in (front, side1, side2, diag):
                    if not solid(*cell):
                        sky_sum += at(sky, *cell, 15)
                        block_sum += at(block, *cell, 0)
                        count += 1
                if count == 0:
                    sky_sum, block_sum, count = at(sky, *front, 15), at(block, *front, 0), 1
                light.append((block_sum / count / 15.0, sky_sum / count / 15.0))
            if kind.light:
                light = [(1.0, value[1]) for value in light]
            tile = kind.top if normal[1] != 0 else kind.side
            tint = kind.side_tint if (kind.side_tint and normal[1] == 0) else kind.tint
            if code == GRASS and normal[1] == 0:
                tint = (1.0, 1.0, 1.0)
            layer = "water" if kind.layer == "translucent" else kind.layer
            builder = builders[layer]
            base = builder.count
            builder.count += 4
            builder.pos.append(np.asarray(positions, np.float32))
            builder.nrm.append(np.tile(np.asarray(normal, np.float32), (4, 1)))
            builder.uv.append(np.asarray(_tile_uvs(tile), np.float32))
            builder.col.append(np.column_stack([np.full(4, tint[0], np.float32), np.full(4, tint[1], np.float32),
                                                np.full(4, tint[2], np.float32), np.asarray(ao, np.float32)]))
            builder.lm.append(np.asarray(light, np.float32))
            builder.ent.append(np.full((4, 1), block_id(kind.name), np.float32))
            builder.idx.append(np.array([base, base + 1, base + 2, base + 2, base + 3, base], np.uint32).reshape(2, 3))
    return {name: builder.finish() for name, builder in builders.items()}


def load_city(cache_dir: Path | None = None) -> tuple[np.ndarray, None, dict[str, Batch]]:
    """``(atlas, None, batches)`` for the city block, cached like the island."""
    properties = (Path(__file__).resolve().parents[1] / "shaders" / "block.properties").read_bytes()
    source = Path(__file__).read_bytes()
    key = hashlib.sha256(source + properties).hexdigest()[:16]
    cache = (cache_dir or Path(__file__).resolve().parent / ".cache") / f"city-{key}.npz"
    atlas = build_city_atlas()
    fields = ("pos", "nrm", "uv", "col", "lm", "idx", "ent")
    if cache.is_file():
        try:
            with np.load(cache) as data:
                batches = {name: Batch(*(data[f"{name}_{field}"] for field in fields)) for name in ("opaque", "cutout", "water")}
            return atlas, None, batches
        except (KeyError, ValueError, OSError):
            cache.unlink(missing_ok=True)
    batches = build_city_batches(build_city_grid())
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache, **{f"{name}_{field}": getattr(batch, field) for name, batch in batches.items() for field in fields})
    return atlas, None, batches


CITY_CAMERAS = {
    # Standing on the road, looking east along the canal and the north towers.
    "street": dict(eye=(-56.0, 65.62, 12.5), yaw=np.pi * 0.5 + 0.10, pitch=-0.04, fov=70.0),
    # On the south quay, looking across the canal at the towers' reflections.
    "canal": dict(eye=(-44.0, 65.62, -7.5), yaw=np.pi * 0.5 - 0.55, pitch=-0.10, fov=70.0),
    # Below the glass tower, looking up its curtain wall.
    "facade": dict(eye=(-26.0, 65.62, 11.0), yaw=-0.75, pitch=0.42, fov=70.0),
    # Above the block, the establishing frame.
    "aerial": dict(eye=(-74.0, 104.0, -52.0), yaw=0.90, pitch=-0.40, fov=70.0),
    # Down the south road between the park and the low buildings.
    "avenue": dict(eye=(-56.0, 65.62, -15.5), yaw=np.pi * 0.5 - 0.06, pitch=-0.03, fov=70.0),
}


if __name__ == "__main__":
    import time

    started = time.perf_counter()
    atlas, _, batches = load_city()
    for name, batch in batches.items():
        print(f"{name:8s} {batch.count:7d} triangles")
    print(f"built in {time.perf_counter() - started:.1f}s")
