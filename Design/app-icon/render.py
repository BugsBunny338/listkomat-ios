#!/usr/bin/env python3
"""Regenerate every Lístkomat app-icon output from backpack.svg.

    python3 Design/app-icon/render.py [--android-repo ../listkomat-android]

writes
    Design/app-icon/icon-1024.svg                                     composition
    Listkomat/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png      iOS
    <android-repo>/app/src/main/res/drawable/ic_launcher_foreground.xml
    <android-repo>/play/assets/icon-512.png                           Play listing
    <android-repo>/play/assets/feature-1024x500.png                   Play feature graphic

and checks that the Android foreground stays inside the 66 dp safe circle.

backpack.svg itself was made once from the 2016 original with

    python3 Design/app-icon/render.py backpack <TicketBuyer_logo.svg>

which turns the "2" <text> into an outline from AlteHaasGroteskBold.ttf so no
font is needed to render the icon. Needs rsvg-convert (brew install librsvg),
fontTools and Pillow. See README.md for the fill rule.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_ROOT = os.path.dirname(os.path.dirname(HERE))
BACKPACK = os.path.join(HERE, "backpack.svg")
FONT = os.path.join(IOS_ROOT, "Listkomat/Resources/Fonts/AlteHaasGroteskBold.ttf")

TEAL = "#56C4CF"
# Art height (stroke outline included) as a fraction of the visible tile.
# Fitted by pixel diff against the 2016 icon60@3.png — see README.md.
FILL = 0.77
# Horizontal centre of the backpack body (straps excluded), in art units.
BODY_CX = (13.57 + 81.19) / 2

# Play feature graphic (px). Layout of the 2026-09-22 graphic it replaces:
# ink title and dark-teal subtitle left, the art centred where its ticket was.
FEATURE_W, FEATURE_H = 1024, 500
FEATURE_INK, FEATURE_SUB = "#1F1F1F", "#0F464C"
# (text, cap height, baseline, left), measured from the old graphic's ink.
FEATURE_TITLE = ("Lístkomat", 78, 258, 78)
FEATURE_SUBTITLE = ("SMS jízdenky na MHD", 33, 333, 73)
# The art sits where the old 300 x 184 px ticket glyph was centred. Its height
# is set by eye: an outline drawing is much lighter than that solid glyph, so
# neither the glyph's height nor its bounding-box area gives the same weight.
FEATURE_ART_HEIGHT, FEATURE_ART_CENTRE = 256, (810, 250)
# Minimum gap between the text block and the art, and to the canvas edges.
FEATURE_MARGIN = 40

# Android adaptive icon geometry (dp).
CANVAS, VISIBLE, SAFE_RADIUS = 108, 72, 33

SVG_NS = "http://www.w3.org/2000/svg"
TRANSLATE = re.compile(r"\s*translate\(\s*(-?[\d.]+)[\s,]+(-?[\d.]+)\s*\)\s*")
ET.register_namespace("", SVG_NS)


def parse_translate(transform):
    """The art only uses translate(x y); refuse anything else rather than misread it."""
    m = TRANSLATE.fullmatch(transform)
    if not m:
        sys.exit("unsupported transform %r: only translate(x y)" % transform)
    return float(m.group(1)), float(m.group(2))


# ---------------------------------------------------------------- backpack.svg

def build_backpack(original):
    """Rewrite the 2016 SVG with presentation attributes and the "2" as a path."""
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont

    root = ET.parse(original).getroot()
    vb = root.get("viewBox")
    # One-shot conversion of that exact file: its three CSS classes are mapped
    # by hand and its one <line> is horizontal.
    style = {
        "cls-1": dict(stroke_miterlimit="10"),
        "cls-2": dict(stroke_linecap="round", stroke_linejoin="round"),
        "cls-3": dict(stroke_linecap="round", stroke_miterlimit="10"),
    }
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s">' % vb,
           "  <!-- 2016 Lístkomat backpack, recovered from iCloud (TicketBuyer_logo.svg).",
           "       The \"2\" is Alte Haas Grotesk Bold 31.99 px as an outline. -->"]
    for el in root:
        tag = el.tag.split("}")[1]
        cls = el.get("class")
        if tag == "path":
            d, transform = el.get("d"), el.get("transform")
        elif tag == "line":
            d, transform = "M%s,%sH%s" % (el.get("x1"), el.get("y1"), el.get("x2")), None
        elif tag == "text":
            font = TTFont(FONT)
            glyphs = font.getGlyphSet()
            name = font.getBestCmap()[ord(el.text)]
            scale = 31.99 / font["head"].unitsPerEm
            tx, ty = parse_translate(el.get("transform"))
            pen = SVGPathPen(glyphs, ntos=lambda v: ("%.2f" % v).rstrip("0").rstrip("."))
            glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, tx, ty)))
            out.append('  <path fill="#fff" d="%s"/>' % pen.getCommands())
            continue
        else:
            continue
        attrs = dict(fill="none", stroke="#fff", stroke_width="4", **style[cls])
        if transform:
            attrs["transform"] = transform
        out.append("  <path %s d=\"%s\"/>" % (
            " ".join('%s="%s"' % (k.replace("_", "-"), v) for k, v in attrs.items()), d))
    out.append("</svg>")
    with open(BACKPACK, "w") as f:
        f.write("\n".join(out) + "\n")
    print("wrote", BACKPACK)


# ---------------------------------------------------------------- rendering

def load_backpack():
    root = ET.parse(BACKPACK).getroot()
    _, _, w, h = map(float, root.get("viewBox").split())
    return root, w, h


def placement(canvas, art_height, h):
    """Scale and offset that put the art `art_height` tall, centred on `canvas`."""
    scale = art_height / h
    return scale, canvas / 2 - BODY_CX * scale, (canvas - h * scale) / 2


def art_group(root, scale, tx, ty):
    """The backpack as an SVG <g>, scaled and moved into place."""
    body = "\n".join("    " + ET.tostring(el, encoding="unicode").strip()
                     .replace(' xmlns="%s"' % SVG_NS, "") for el in root)
    return '  <g transform="translate({:.4f} {:.4f}) scale({:.6f})">\n{}\n  </g>\n'.format(
        tx, ty, scale, body)


def composition_svg(size, fill=FILL):
    """Full-bleed teal square with the backpack centred at `fill` of the height."""
    root, w, h = load_backpack()
    scale, tx, ty = placement(size, size * fill, h)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" viewBox="0 0 {s} {s}">\n'
            '  <rect width="{s}" height="{s}" fill="{teal}"/>\n{art}</svg>\n'
            ).format(s=size, teal=TEAL, art=art_group(root, scale, tx, ty))


def rasterize(svg_text, px, dest, alpha=False, height=None):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
    try:
        subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(height or px), "-o", dest, f.name],
                       check=True)
    finally:
        os.unlink(f.name)
    # Opaque either way. App Store Connect rejects icons with an alpha channel
    # and Play rejects it on the feature graphic; only the Play icon, a 32-bit
    # PNG by Play's spec, passes alpha=True.
    from PIL import Image
    Image.open(dest).convert("RGBA" if alpha else "RGB").save(dest, optimize=True)


def text_path(font, text, cap_height, baseline, left):
    """Outline `text` in `font` with its ink starting at `left`.

    Returns (path data, ink bounds as (x0, y0, x1, y1) in px). Applies the
    legacy `kern` table if there is one; GPOS kerning is not read (none of it
    applies to the current strings either).
    """
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen

    glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
    kern = font["kern"].kernTables[0].kernTable if "kern" in font else {}
    missing = [c for c in text if ord(c) not in cmap]
    if missing:
        sys.exit("font has no glyph for %r" % "".join(missing))
    names = [cmap[ord(c)] for c in text]
    scale = cap_height / font["OS/2"].sCapHeight
    # Pen positions in font units, then shift so the ink starts at `left`.
    xs, x = [], 0
    for i, name in enumerate(names):
        xs.append(x)
        x += glyphs[name].width + (kern.get((name, names[i + 1]), 0) if i + 1 < len(names) else 0)
    bounds = BoundsPen(glyphs)
    for name, gx in zip(names, xs):
        glyphs[name].draw(TransformPen(bounds, (1, 0, 0, 1, gx, 0)))
    if bounds.bounds is None:
        sys.exit("text %r has no ink" % text)
    x0, y0, x1, y1 = bounds.bounds
    origin = left - x0 * scale
    pen = SVGPathPen(glyphs, ntos=lambda v: ("%.2f" % v).rstrip("0").rstrip("."))
    for name, gx in zip(names, xs):
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, origin + gx * scale, baseline)))
    return pen.getCommands(), (left, baseline - y1 * scale, origin + x1 * scale, baseline - y0 * scale)


def feature_svg():
    """Play feature graphic: teal, title + subtitle left, the backpack right."""
    from fontTools.ttLib import TTFont

    font = TTFont(FONT)
    title, title_box = text_path(font, *FEATURE_TITLE)
    subtitle, subtitle_box = text_path(font, *FEATURE_SUBTITLE)
    root, w, h = load_backpack()
    scale = FEATURE_ART_HEIGHT / h
    cx, cy = FEATURE_ART_CENTRE
    tx, ty = cx - BODY_CX * scale, cy - FEATURE_ART_HEIGHT / 2
    # Refuse a layout where the text runs into the art or anything leaves the canvas.
    text_right = max(title_box[2], subtitle_box[2])
    boxes = [title_box, subtitle_box, (tx, ty, tx + w * scale, ty + FEATURE_ART_HEIGHT)]
    if any(b[0] < 0 or b[1] < FEATURE_MARGIN or b[2] > FEATURE_W or b[3] > FEATURE_H - FEATURE_MARGIN
           for b in boxes) or text_right + FEATURE_MARGIN > tx:
        sys.exit("feature graphic layout overlaps or leaves the canvas: %r" % boxes)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
            '  <rect width="{w}" height="{h}" fill="{teal}"/>\n'
            '  <path fill="{ink}" d="{title}"/>\n'
            '  <path fill="{sub}" d="{subtitle}"/>\n{art}</svg>\n'
            ).format(w=FEATURE_W, h=FEATURE_H, teal=TEAL, ink=FEATURE_INK, sub=FEATURE_SUB,
                     title=title, subtitle=subtitle, art=art_group(root, scale, tx, ty))


def normalize_path(d):
    """Re-serialize compact SVG path data with explicit separators for Android."""
    token = r"[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
    tokens = re.findall(token, d)
    # Everything but the tokens must be separators, or data would be dropped.
    # Arc flags must be separated too: "0112" would parse as one number.
    if not re.fullmatch(r"[\s,]*", re.sub(token, "", d)):
        sys.exit("unsupported path data: %r" % d[:60])
    arc_args = None
    for t in tokens:
        if t.isalpha():
            arc_args = 0 if t in "Aa" else None
        elif arc_args is not None:
            if arc_args % 7 in (3, 4) and t not in ("0", "1"):
                sys.exit("arc flag %r in %r: flags need separators" % (t, d[:60]))
            arc_args += 1
    return " ".join(re.sub(r"^(-?)\.", r"\g<1>0.", t) for t in tokens)


def android_foreground():
    """VectorDrawable on the 108 dp adaptive canvas, same art and fill as iOS."""
    root, w, h = load_backpack()
    scale, tx, ty = placement(CANVAS, VISIBLE * FILL, h)
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!-- Generated by listkomat-ios Design/app-icon/render.py — do not hand-edit. -->",
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="%ddp" android:height="%ddp"' % (CANVAS, CANVAS),
        '    android:viewportWidth="%d" android:viewportHeight="%d">' % (CANVAS, CANVAS),
        '    <group android:translateX="%.4f" android:translateY="%.4f"' % (tx, ty),
        '        android:scaleX="%.6f" android:scaleY="%.6f">' % (scale, scale),
    ]
    for el in root:
        attrs = []
        if el.get("fill", "none") != "none":
            attrs.append('android:fillColor="#FFFFFF"')
        if el.get("stroke"):
            attrs += ['android:strokeColor="#FFFFFF"',
                      'android:strokeWidth="%s"' % el.get("stroke-width")]
            if el.get("stroke-linecap"):
                attrs.append('android:strokeLineCap="%s"' % el.get("stroke-linecap"))
            if el.get("stroke-linejoin"):
                attrs.append('android:strokeLineJoin="%s"' % el.get("stroke-linejoin"))
            if el.get("stroke-miterlimit"):
                attrs.append('android:strokeMiterLimit="%s"' % el.get("stroke-miterlimit"))
        attrs.append('android:pathData="%s" />' % normalize_path(el.get("d")))
        transform = el.get("transform")
        indent = " " * (12 if transform else 8)
        if transform:
            gx, gy = parse_translate(transform)
            lines.append('        <group android:translateX="%s" android:translateY="%s">' % (gx, gy))
        lines.append(indent + "<path")
        lines += [indent + "    " + a for a in attrs]
        if transform:
            lines.append("        </group>")
    lines += ["    </group>", "</vector>"]
    return "\n".join(lines) + "\n"


def check_safe_zone(tmpdir):
    """Render the foreground geometry and measure the art's reach from the centre."""
    from PIL import Image
    px_per_dp = 10
    size = CANVAS * px_per_dp
    svg = composition_svg(size, fill=FILL * VISIBLE / CANVAS)
    png = os.path.join(tmpdir, "fg.png")
    rasterize(svg, size, png)
    im = Image.open(png).convert("L")
    data, c, reach = im.load(), size / 2, 0.0
    for y in range(size):
        for x in range(size):
            if data[x, y] > 180:  # teal is ~164; count antialiased edges as art
                reach = max(reach, ((x + .5 - c) ** 2 + (y + .5 - c) ** 2) ** .5)
    reach /= px_per_dp
    print("android foreground: art %.1f dp tall, reaches %.1f dp from centre (safe zone %d dp)"
          % (VISIBLE * FILL, reach, SAFE_RADIUS))
    if reach > SAFE_RADIUS:
        sys.exit("art leaves the adaptive-icon safe zone")


def render(android_repo):
    icon = composition_svg(1024)
    with open(os.path.join(HERE, "icon-1024.svg"), "w") as f:
        f.write(icon)
    rasterize(icon, 1024,
              os.path.join(IOS_ROOT, "Listkomat/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"))
    print("wrote icon-1024.svg, AppIcon1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        check_safe_zone(tmp)
    if android_repo:
        with open(os.path.join(android_repo, "app/src/main/res/drawable/ic_launcher_foreground.xml"), "w") as f:
            f.write(android_foreground())
        rasterize(icon, 512, os.path.join(android_repo, "play/assets/icon-512.png"),
                  alpha=True)
        # Play wants the feature graphic without alpha.
        rasterize(feature_svg(), FEATURE_W, os.path.join(android_repo, "play/assets/feature-1024x500.png"),
                  height=FEATURE_H)
        print("wrote", android_repo,
              "ic_launcher_foreground.xml, play/assets/icon-512.png, play/assets/feature-1024x500.png")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", nargs="?", default="render", choices=["render", "backpack"])
    ap.add_argument("original", nargs="?", help="TicketBuyer_logo.svg (backpack command)")
    ap.add_argument("--android-repo", help="listkomat-android checkout to write into")
    args = ap.parse_args()
    if args.command == "backpack":
        if not args.original:
            ap.error("backpack needs the original TicketBuyer_logo.svg")
        build_backpack(args.original)
    else:
        render(args.android_repo)


if __name__ == "__main__":
    main()
