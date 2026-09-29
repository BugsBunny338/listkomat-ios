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
FEATURE_TITLE = ("Lístkomat", 78, 257, 78)             # text, cap height, baseline, left
FEATURE_SUBTITLE = ("SMS jízdenky na MHD", 34, 333, 73)
# The old ticket glyph was 300 x 184 px; the art gets the same bounding-box
# area (the README's visual-weight measure), centred on the same point.
FEATURE_ART_AREA, FEATURE_ART_CENTRE = 300 * 184, (810, 250)

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


def composition_svg(size, fill=FILL):
    """Full-bleed teal square with the backpack centred at `fill` of the height."""
    root, w, h = load_backpack()
    scale, tx, ty = placement(size, size * fill, h)
    body = "\n".join("    " + ET.tostring(el, encoding="unicode").strip()
                     .replace(' xmlns="%s"' % SVG_NS, "") for el in root)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" viewBox="0 0 {s} {s}">\n'
            '  <rect width="{s}" height="{s}" fill="{teal}"/>\n'
            '  <g transform="translate({tx:.4f} {ty:.4f}) scale({sc:.6f})">\n{body}\n  </g>\n</svg>\n'
            ).format(s=size, teal=TEAL, tx=tx, ty=ty, sc=scale, body=body)


def rasterize(svg_text, px, dest, alpha=False, height=None):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
    try:
        subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(height or px), "-o", dest, f.name],
                       check=True)
    finally:
        os.unlink(f.name)
    # The tile is opaque either way. App Store Connect rejects icons with an
    # alpha channel; Play asks for a 32-bit PNG, so that one keeps it.
    from PIL import Image
    Image.open(dest).convert("RGBA" if alpha else "RGB").save(dest, optimize=True)


def text_path(text, cap_height, baseline, left):
    """Outline `text` in Alte Haas Grotesk Bold, kerned, with its ink starting at `left`."""
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont

    font = TTFont(FONT)
    glyphs, cmap, glyf = font.getGlyphSet(), font.getBestCmap(), font["glyf"]
    kern = font["kern"].kernTables[0].kernTable
    scale = cap_height / font["OS/2"].sCapHeight
    names = [cmap[ord(c)] for c in text]
    pen = SVGPathPen(glyphs, ntos=lambda v: ("%.2f" % v).rstrip("0").rstrip("."))
    x = -glyf[names[0]].xMin  # font units; puts the first glyph's ink at `left`
    for i, name in enumerate(names):
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, left + x * scale, baseline)))
        x += glyphs[name].width + (kern.get((name, names[i + 1]), 0) if i + 1 < len(names) else 0)
    return pen.getCommands()


def feature_svg():
    """Play feature graphic: teal, title + subtitle left, the backpack right."""
    root, w, h = load_backpack()
    art_h = (FEATURE_ART_AREA * h / w) ** .5
    cx, cy = FEATURE_ART_CENTRE
    scale = art_h / h
    tx, ty = cx - BODY_CX * scale, cy - art_h / 2
    body = "\n".join("    " + ET.tostring(el, encoding="unicode").strip()
                     .replace(' xmlns="%s"' % SVG_NS, "") for el in root)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
            '  <rect width="{w}" height="{h}" fill="{teal}"/>\n'
            '  <path fill="{ink}" d="{title}"/>\n'
            '  <path fill="{sub}" d="{subtitle}"/>\n'
            '  <g transform="translate({tx:.4f} {ty:.4f}) scale({sc:.6f})">\n{body}\n  </g>\n</svg>\n'
            ).format(w=FEATURE_W, h=FEATURE_H, teal=TEAL, ink=FEATURE_INK, sub=FEATURE_SUB,
                     title=text_path(*FEATURE_TITLE), subtitle=text_path(*FEATURE_SUBTITLE),
                     tx=tx, ty=ty, sc=scale, body=body)


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
    with open(os.path.join(HERE, "icon-1024.svg"), "w") as f:
        f.write(composition_svg(1024))
    rasterize(composition_svg(1024), 1024,
              os.path.join(IOS_ROOT, "Listkomat/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"))
    print("wrote icon-1024.svg, AppIcon1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        check_safe_zone(tmp)
    if android_repo:
        with open(os.path.join(android_repo, "app/src/main/res/drawable/ic_launcher_foreground.xml"), "w") as f:
            f.write(android_foreground())
        rasterize(composition_svg(1024), 512, os.path.join(android_repo, "play/assets/icon-512.png"),
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
