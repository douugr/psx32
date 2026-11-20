# Original PSX32 icon: black disc with a rainbow sheen, silver "PSX" lettering and a "32" badge.
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

S = 1024
def font(size):
    for p in ["/System/Library/Fonts/Supplemental/Futura.ttc", "/Library/Fonts/Futura.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        try: return ImageFont.truetype(p, size, index=4) if p.endswith(".ttc") else ImageFont.truetype(p, size)
        except (OSError, IndexError):
            try: return ImageFont.truetype(p, size)
            except OSError: pass
    return ImageFont.load_default()

img = Image.new("RGB", (S, S), (14, 14, 18))
d = ImageDraw.Draw(img)
for y in range(0, S, 8):   # scanlines
    d.line([(0, y), (S, y)], fill=(19, 19, 24), width=3)

# disc
cx, cy, R = 620, 470, 430
disc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dd = ImageDraw.Draw(disc)
dd.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(10, 10, 14, 255), outline=(110, 110, 120, 255), width=6)
rainbow = [(89, 217, 255), (115, 115, 255), (217, 102, 242), (255, 128, 115), (255, 217, 89), (140, 242, 153)]
for base in (15, 195):
    for i, c in enumerate(rainbow):
        a0 = base + i * 6
        dd.pieslice([cx - R + 8, cy - R + 8, cx + R - 8, cy + R - 8], a0, a0 + 6, fill=c + (95,))
sheen = disc.filter(ImageFilter.GaussianBlur(6))
disc = Image.alpha_composite(sheen, Image.new("RGBA", (S, S), (0, 0, 0, 0)))
dd = ImageDraw.Draw(disc)
for k in range(10):
    r = R * (0.42 + k * 0.055)
    dd.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 14), width=2)
dd.ellipse([cx - R * 0.34, cy - R * 0.34, cx + R * 0.34, cy + R * 0.34], fill=(120, 120, 130, 110))
dd.ellipse([cx - R * 0.12, cy - R * 0.12, cx + R * 0.12, cy + R * 0.12], fill=(14, 14, 18, 255))
dd.ellipse([cx - R, cy - R, cx + R, cy + R], outline=(120, 120, 130, 255), width=5)
img.paste(disc, (0, 0), disc)

# silver "PSX"
f = font(330)
text = "PSX"
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
tx, ty = 60, 520
md.text((tx, ty), text, font=f, fill=255)
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
stops = [(0.0, (255, 255, 255)), (0.42, (200, 204, 216)), (0.52, (96, 100, 114)), (0.62, (221, 224, 234)), (1.0, (150, 154, 168))]
bbox = mask.getbbox()
top, bot = bbox[1], bbox[3]
for y in range(S):
    t = min(max((y - top) / max(bot - top, 1), 0), 1)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if p0 <= t <= p1:
            u = (t - p0) / (p1 - p0)
            gd.line([(0, y), (S, y)], fill=tuple(int(c0[i] + (c1[i] - c0[i]) * u) for i in range(3)))
            break
outline = mask.filter(ImageFilter.MaxFilter(23))
glow = outline.filter(ImageFilter.GaussianBlur(18))
img.paste((61, 143, 255), (0, 0), glow.point(lambda v: int(v * 0.55)))
img.paste((4, 4, 6), (0, 0), outline)
img.paste(grad, (0, 0), mask)

# "32" badge
bd = ImageDraw.Draw(img)
bx0, by0, bx1, by1 = 640, 830, 960, 990
bd.rounded_rectangle([bx0, by0, bx1, by1], radius=36, fill=(61, 143, 255))
f2 = font(150)
w = bd.textlength("32", font=f2)
bd.text(((bx0 + bx1) / 2 - w / 2, by0 - 14), "32", font=f2, fill=(255, 255, 255))
# rainbow bands bottom-left
for i, c in enumerate(rainbow[:3]):
    bd.rectangle([0, 870 + i * 34, 600, 870 + i * 34 + 22], fill=c)

out = sys.argv[1]
for name, px in [("Icon-60@2x", 120), ("Icon-60@3x", 180), ("Icon-76", 76), ("Icon-76@2x", 152), ("icon-1024", 1024)]:
    img.resize((px, px), Image.LANCZOS).save(f"{out}/{name}.png")
