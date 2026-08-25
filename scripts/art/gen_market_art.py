#!/usr/bin/env python3
"""Turn the committed nano-banana renders into Fruit Market's board art.

Sources (committed under ``scripts/art/source/``, generated once with
``gemini-2.5-flash-image`` per ``playbooks/art-nanobanana.md``):

===========================  =========================================
``cogs_a.png``               four cogs in a row: red, orange, yellow, lime
``cogs_b.png``               four cogs in a row: light blue, blue, pink, white
``tiles.png``                a grid of seamless top-down ground tiles
``trees.png``                apple tree, apple tree, banana palm, banana palm
``fruit.png``                one apple, one banana bunch
``stalls.png``               four striped market stalls
``lockerroom_bg.png``        the market square at dawn (loading screen)
===========================  =========================================

Gemini returns no alpha and the "pure green" backdrop comes back as *some*
green with a tinted edge, so every character/object sheet is chroma-keyed by
flood-filling from the border with the median border colour as the key. Ground
tiles are cropped, not keyed — they are supposed to be opaque.

Everything this writes is committed; CI never regenerates art. Run it from the
repository root:

    python3 -m pip install --user pillow
    python3 scripts/art/gen_market_art.py

This generator owns EVERY file it writes below. Nothing else in the repo draws
board art procedurally; ``src/fruit_market/global.nim`` only falls back to a
flat colour plate when one of these files is missing, so a missing asset
degrades to a drawable board instead of an aborted runtime.
"""

from __future__ import annotations

import os
from collections import deque

from PIL import Image, ImageChops, ImageEnhance, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "scripts", "art", "source")
DATA = os.path.join(ROOT, "data")
LOCKER = os.path.join(ROOT, "client", "art", "lockerroom")

CELL = 48
COG_W, COG_H = 36, 48
FRUIT_PX = 22
STALL_W, STALL_H = 96, 64

COG_COLOURS = [
    ("red", "cogs_a", 0),
    ("orange", "cogs_a", 1),
    ("yellow", "cogs_a", 2),
    ("lime", "cogs_a", 3),
    ("light_blue", "cogs_b", 0),
    ("blue", "cogs_b", 1),
    ("pink", "cogs_b", 2),
    ("white", "cogs_b", 3),
]

STALL_NAMES = ["north", "east", "south", "west"]


def load(name: str) -> Image.Image:
    return Image.open(os.path.join(SOURCE, name + ".png")).convert("RGBA")


def median_border(image: Image.Image) -> tuple[int, int, int]:
    """The backdrop colour, taken as the median of the border ring.

    The corners sometimes carry a smudge, so a single corner pixel is not
    trustworthy and the mean is dragged by it; the median is neither.
    """
    pixels = image.load()
    width, height = image.size
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)  # type: ignore[return-value]


def chroma_key(image: Image.Image, tolerance: int = 78) -> Image.Image:
    """Flood-fill the backdrop from the border so green *inside* a cog lives.

    A global colour threshold would eat a lime cog whole. Filling from the
    edge only removes backdrop that is actually connected to the edge.
    """
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    key = median_border(image)
    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def near(colour) -> bool:
        return (
            abs(colour[0] - key[0]) + abs(colour[1] - key[1]) + abs(colour[2] - key[2])
        ) <= tolerance

    for x in range(width):
        for y in (0, height - 1):
            if not seen[y * width + x] and near(pixels[x, y]):
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[y * width + x] and near(pixels[x, y]):
                seen[y * width + x] = 1
                queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and not seen[ny * width + nx]:
                if near(pixels[nx, ny]):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def columns_with_content(image: Image.Image) -> list[tuple[int, int]]:
    """Split a keyed row sheet on its empty columns."""
    alpha = image.split()[3]
    width, height = image.size
    filled = []
    for x in range(width):
        column = alpha.crop((x, 0, x + 1, height))
        filled.append(column.getextrema()[1] > 24)
    spans = []
    start = None
    for x, has in enumerate(filled):
        if has and start is None:
            start = x
        elif not has and start is not None:
            if x - start > width // 40:
                spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, width))
    return spans


def split_row(image: Image.Image, count: int) -> list[Image.Image]:
    """`count` sprites out of one keyed row, cropped to their own alpha box."""
    spans = columns_with_content(image)
    if len(spans) != count:
        # The model does not always honour "one row"; fall back to even slices,
        # which is still correct for a sheet laid out on a regular grid.
        step = image.width // count
        spans = [(i * step, (i + 1) * step) for i in range(count)]
    parts = []
    for left, right in spans:
        part = image.crop((left, 0, right, image.height))
        box = part.split()[3].getbbox()
        parts.append(part.crop(box) if box else part)
    return parts


def fit(image: Image.Image, width: int, height: int) -> Image.Image:
    """Scale to fit and centre on a transparent canvas of exactly w x h."""
    source = image.copy()
    source.thumbnail((width, height), Image.LANCZOS)
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.paste(
        source,
        ((width - source.width) // 2, height - source.height),
        source,
    )
    return canvas


def grid_cells(image: Image.Image, cols: int, rows: int) -> list[Image.Image]:
    cw, ch = image.width // cols, image.height // rows
    cells = []
    for row in range(rows):
        for col in range(cols):
            cells.append(
                image.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch))
            )
    return cells


def tile(image: Image.Image) -> Image.Image:
    """A ground tile: crop the middle (the model paints borders), then scale."""
    inset = min(image.width, image.height) // 10
    core = image.crop(
        (inset, inset, image.width - inset, image.height - inset)
    ).convert("RGB")
    return core.resize((CELL, CELL), Image.LANCZOS).convert("RGBA")


def strip_fruit(image: Image.Image, hue: str) -> Image.Image:
    """Derive a BARE tree from a ripe one.

    Both tree renders came back fruited, so the bare state is derived: the
    fruit's own hue is replaced with the canopy's leaf green and the whole
    canopy is dulled, which reads as "picked" at board scale.
    """
    out = image.copy()
    pixels = out.load()
    leaf = (74, 112, 54, 255)
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = pixels[x, y]
            if a < 24:
                continue
            if hue == "red" and r > 110 and r > g + 40 and r > b + 40:
                pixels[x, y] = leaf
            elif hue == "yellow" and r > 140 and g > 120 and b < g - 40:
                pixels[x, y] = leaf
    return ImageEnhance.Color(out).enhance(0.6)


def wade_pose(front: Image.Image) -> Image.Image:
    """Half submerged, with a splash line where the water cuts the body."""
    out = Image.new("RGBA", front.size, (0, 0, 0, 0))
    line = int(front.height * 0.60)
    out.paste(front.crop((0, 0, front.width, line)), (0, 0))
    splash = Image.new("RGBA", (front.width, 5), (196, 228, 248, 205))
    out.alpha_composite(splash, (0, max(0, line - 3)))
    return out


def slump_pose(front: Image.Image) -> Image.Image:
    """Squashed and greyed: an exhausted cog on the floor."""
    squashed = front.resize(
        (front.width, max(1, int(front.height * 0.7))), Image.LANCZOS
    )
    out = Image.new("RGBA", front.size, (0, 0, 0, 0))
    out.paste(squashed, (0, front.height - squashed.height), squashed)
    return ImageEnhance.Color(out).enhance(0.25)


def write(image: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)
    print("wrote", os.path.relpath(path, ROOT), image.size)


def main() -> None:
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(LOCKER, exist_ok=True)

    # ---- ground -----------------------------------------------------------
    tiles = grid_cells(load("tiles").convert("RGB"), 3, 3)
    write(tile(tiles[0]), os.path.join(DATA, "floor_orchard.png"))
    write(tile(tiles[3]), os.path.join(DATA, "floor_market.png"))
    write(tile(tiles[1]), os.path.join(DATA, "floor_island.png"))
    still = tile(tiles[4])
    write(still, os.path.join(DATA, "water_still.png"))
    ripple = ImageEnhance.Brightness(still).enhance(1.18)
    ripple = ripple.filter(ImageFilter.GaussianBlur(0.6))
    ripple = ImageChops.offset(ripple, 3, 2)
    write(ripple, os.path.join(DATA, "water_ripple.png"))
    write(tile(tiles[2]), os.path.join(DATA, "wall_stone.png"))

    # ---- trees ------------------------------------------------------------
    trees = split_row(chroma_key(load("trees")), 4)
    apple = fit(trees[0], CELL, CELL)
    banana = fit(trees[2], CELL, CELL)
    write(apple, os.path.join(DATA, "tree_apple_ripe.png"))
    write(strip_fruit(apple, "red"), os.path.join(DATA, "tree_apple_bare.png"))
    write(banana, os.path.join(DATA, "tree_banana_ripe.png"))
    write(strip_fruit(banana, "yellow"), os.path.join(DATA, "tree_banana_bare.png"))

    # ---- fruit ------------------------------------------------------------
    fruit = split_row(chroma_key(load("fruit")), 2)
    write(fit(fruit[0], FRUIT_PX, FRUIT_PX), os.path.join(DATA, "fruit_apple.png"))
    write(fit(fruit[1], FRUIT_PX, FRUIT_PX), os.path.join(DATA, "fruit_banana.png"))

    # ---- stalls -----------------------------------------------------------
    stalls = split_row(chroma_key(load("stalls")), 4)
    for name, part in zip(STALL_NAMES, stalls):
        write(fit(part, STALL_W, STALL_H), os.path.join(DATA, f"stall_{name}.png"))

    # ---- cogs -------------------------------------------------------------
    sheets = {
        "cogs_a": split_row(chroma_key(load("cogs_a")), 4),
        "cogs_b": split_row(chroma_key(load("cogs_b")), 4),
    }
    portraits = []
    for colour, sheet, index in COG_COLOURS:
        raw = sheets[sheet][index]
        front = fit(raw, COG_W, COG_H)
        write(front, os.path.join(DATA, f"cog_{colour}_front.png"))
        write(wade_pose(front), os.path.join(DATA, f"cog_{colour}_wade.png"))
        write(slump_pose(front), os.path.join(DATA, f"cog_{colour}_slump.png"))
        portraits.append(raw)

    # ---- offer bubble frame + trade burst ---------------------------------
    bubble = Image.new("RGBA", (96, 26), (0, 0, 0, 0))
    from PIL import ImageDraw

    draw = ImageDraw.Draw(bubble)
    draw.rounded_rectangle((0, 0, 95, 25), radius=8, fill=(24, 18, 12, 220),
                           outline=(232, 214, 178, 235), width=2)
    write(bubble, os.path.join(DATA, "offer_bubble.png"))

    burst = Image.new("RGBA", (48, 48), (0, 0, 0, 0))
    draw = ImageDraw.Draw(burst)
    for radius, alpha in ((22, 60), (15, 110), (8, 200)):
        draw.ellipse(
            (24 - radius, 24 - radius, 24 + radius, 24 + radius),
            fill=(255, 236, 160, alpha),
        )
    write(burst, os.path.join(DATA, "trade_burst.png"))

    # ---- the loading-screen locker room -----------------------------------
    # The inherited #lockerroom markup cycles five poses for each of four
    # named bots. Rather than edit that inherited JS, this fills the exact file
    # names it asks for with the market's own cog kit.
    background = load("lockerroom_bg").convert("RGB")
    background.resize((1280, 1280 * background.height // background.width)).save(
        os.path.join(LOCKER, "bg.jpg"), quality=86
    )
    print("wrote", os.path.relpath(os.path.join(LOCKER, "bg.jpg"), ROOT))
    bots = {"red": 0, "green": 3, "yellow": 2, "blue": 5}
    for bot, source_index in bots.items():
        base = portraits[source_index]
        for pose, (scale, angle) in enumerate(
            [(1.0, 0), (0.98, -4), (0.98, 4), (0.94, -8), (1.02, 2)], start=0
        ):
            frame = base.rotate(angle, expand=True, resample=Image.BICUBIC)
            frame = frame.resize(
                (int(frame.width * scale * 0.5), int(frame.height * scale * 0.5)),
                Image.LANCZOS,
            )
            name = f"{bot}_{[1, 2, 3, 5, 6][pose]}.webp"
            frame.save(os.path.join(LOCKER, name), lossless=False, quality=88)
            print("wrote", os.path.relpath(os.path.join(LOCKER, name), ROOT))


if __name__ == "__main__":
    main()
