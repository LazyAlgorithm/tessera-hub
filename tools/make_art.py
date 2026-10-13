"""Makes the Hub's built-in artwork (src/UI/*.png) from the games' own images. Run from the repository root:
python3 tools/make_art.py <ringfall folder> <tessera folder>. The results are committed; this is only needed to
change them."""
import math, random, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ringfall, tessera = Path(sys.argv[1]), Path(sys.argv[2])
out = Path('src/UI')
W, H = 1500, 600
BG = (12, 16, 24)


def fade(image, strength=1.0):
    """Darkens toward the bottom and the left, into the page's background, so text over it reads."""
    overlay = Image.new('RGBA', image.size)
    pixels = overlay.load()
    for y in range(H):
        for x in range(W):
            bottom = max(0.0, (y / H - 0.35) / 0.65) ** 1.3
            left = max(0.0, 1 - x / (W * 0.55)) ** 2 * 0.55
            a = min(1.0, (bottom + left) * strength)
            pixels[x, y] = BG + (int(a * 255),)
    image = image.convert('RGBA')
    image.alpha_composite(overlay)
    return image.convert('RGB')


def cover(image):
    scale = max(W / image.width, H / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - W) // 2, (image.height - H) // 2
    return image.crop((left, top, left + W, top + H))


# Ringfall: its Foundry arena, slightly blurred so the title over it stays sharp by comparison.
arena = cover(Image.open(ringfall / 'src/UI/map_foundry.png').convert('RGB')).filter(ImageFilter.GaussianBlur(1.2))
fade(arena).save(out / 'banner_ringfall.png')

# Tessera: diamond tiles like its icon, scattered over a dark field, brighter to the right.
random.seed(7)
field = Image.new('RGB', (W, H), BG)
layer = Image.new('RGBA', (W, H))
draw = ImageDraw.Draw(layer)
blues = [(143, 216, 250), (92, 196, 240), (52, 160, 214), (31, 112, 160)]
size = 46
for row in range(-1, H // size + 2):
    for col in range(-1, W // size + 2):
        cx = col * size + (row % 2) * size / 2
        cy = row * size * 0.5
        weight = max(0.0, cx / W) ** 1.6
        if random.random() > 0.15 + weight * 0.8:
            continue
        r = size * 0.42
        color = random.choice(blues) + (int(40 + 170 * weight * random.random()),)
        draw.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=color)
field = field.convert('RGBA')
field.alpha_composite(layer.filter(ImageFilter.GaussianBlur(0.6)))
# The icon's four diamonds, large, without its dark square behind them.
glow = Image.new('RGBA', (W, H))
ImageDraw.Draw(glow).ellipse((W - 560, 20, W - 60, 520), fill=(76, 195, 240, 80))
field.alpha_composite(glow.filter(ImageFilter.GaussianBlur(80)))
cx, cy = W - 310, 270
# Rounded squares turned 45 degrees about each centre: draw them on their own and rotate the whole mark.
pieces = Image.new('RGBA', (600, 600))
draw = ImageDraw.Draw(pieces)
for (dx, dy), color in (((0, -1), (143, 216, 250)), ((-1, 0), (52, 160, 214)), ((1, 0), (92, 196, 240)), ((0, 1), (31, 112, 160))):
    # In the rotated frame the four sit on the diagonals.
    x, y = 300 + (dx - dy) * 66, 300 + (dx + dy) * 66
    draw.rounded_rectangle((x - 58, y - 58, x + 58, y + 58), radius=12, fill=color + (255,))
pieces = pieces.rotate(45, resample=Image.BICUBIC)
field.alpha_composite(pieces, (cx - 300, cy - 300))
fade(field.convert('RGB'), 0.9).save(out / 'banner_tessera.png')

# Small icons for the list.
for name, source in (('icon_ringfall.png', ringfall / 'src/UI/icon.png'), ('icon_tessera.png', tessera / 'icon.png')):
    Image.open(source).convert('RGBA').resize((96, 96), Image.LANCZOS).save(out / name)
print('done')
