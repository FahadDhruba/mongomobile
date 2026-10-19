"""Draws the MongoMobile launcher icon: a three-tier database cylinder."""
import os, sys
from PIL import Image, ImageDraw

NAVY = (0, 30, 43, 255)
TOP = (0, 237, 100, 255)
BODY = (0, 184, 90, 255)
SHADE = (0, 135, 74, 255)
OUT = sys.argv[1]
SS = 8  # supersampling

def draw_cylinder(d, s, color_top, color_body, color_shade, carve, mono=False):
    # Coordinates in the 108-unit adaptive icon grid.
    def u(v): return v * s
    x0, x1 = 33, 75
    eh = 7  # half height of the ellipses
    tiers = [(61, 75), (47, 61), (33, 47)]  # (top y, bottom y) bottom tier first
    gap = 2.2
    img = d._image
    for i, (yt, yb) in enumerate(tiers):
        if i > 0:
            # Carve a gap into the tier below with the background colour.
            d.ellipse([u(x0 - gap), u(yb - eh - gap), u(x1 + gap), u(yb + eh + gap)], fill=carve)
            d.rectangle([u(x0 - gap), u(yt), u(x1 + gap), u(yb)], fill=carve)
        tier = Image.new('L', img.size, 0)
        td = ImageDraw.Draw(tier)
        td.ellipse([u(x0), u(yb - eh), u(x1), u(yb + eh)], fill=255)
        td.rectangle([u(x0), u(yt), u(x1), u(yb)], fill=255)
        img.paste(Image.new('RGBA', img.size, color_body), (0, 0), tier)
        if not mono:
            # Darker right third for depth, clipped to the tier.
            band = Image.new('L', img.size, 0)
            ImageDraw.Draw(band).rectangle([u(x1 - 11), 0, img.size[0], img.size[1]], fill=255)
            from PIL import ImageChops
            img.paste(Image.new('RGBA', img.size, color_shade), (0, 0), ImageChops.multiply(tier, band))
    yt = tiers[-1][0]
    d.ellipse([u(x0), u(yt - eh), u(x1), u(yt + eh)], fill=color_top)
    if not mono:
        # A small cursor mark on the top, a nod to a query prompt.
        d.rounded_rectangle([u(49), u(yt - 1.6), u(59), u(yt + 1.6)], radius=u(1.6), fill=NAVY)

def foreground(px, mono=False):
    s = px * SS / 108
    img = Image.new('RGBA', (px * SS, px * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if mono:
        white = (255, 255, 255, 255)
        draw_cylinder(d, s, white, white, white, (0, 0, 0, 0), mono=True)
    else:
        draw_cylinder(d, s, TOP, BODY, SHADE, (0, 0, 0, 0))
    return img.resize((px, px), Image.LANCZOS)

def legacy(px):
    # Full-bleed rounded square with the cylinder scaled to fill it.
    big = px * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.22, fill=NAVY)
    # The adaptive art uses the inner 72 of 108 units; scale it up.
    s = big / 72
    layer = Image.new('RGBA', (int(108 * s), int(108 * s)), (0, 0, 0, 0))
    draw_cylinder(ImageDraw.Draw(layer), s, TOP, BODY, SHADE, NAVY)
    off = int(18 * s)
    img.alpha_composite(layer.crop((off, off, off + big, off + big)))
    return img.resize((px, px), Image.LANCZOS)

res = os.path.join(OUT, 'android/app/src/main/res')
for name, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
    folder = os.path.join(res, f'mipmap-{name}')
    os.makedirs(folder, exist_ok=True)
    legacy(int(48 * scale)).save(os.path.join(folder, 'ic_launcher.png'))
    foreground(int(108 * scale)).save(os.path.join(folder, 'ic_launcher_foreground.png'))
    foreground(int(108 * scale), mono=True).save(os.path.join(folder, 'ic_launcher_monochrome.png'))

legacy(512).save(os.path.join(OUT, 'assets/icon/app_icon.png'))
legacy(192).save(os.path.join(OUT, 'assets/icon/app_icon_192.png'))
