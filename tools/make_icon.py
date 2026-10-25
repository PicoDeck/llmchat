#!/usr/bin/env python3
"""Draw icon.png: 48x48 8-bit RGB, a speech bubble with ">_" on black.
  python3 tools/make_icon.py [out.png]"""
import sys
from PIL import Image, ImageDraw

ORANGE = (217, 119, 87)   # Claude's colour
BLUE = (30, 58, 104)      # the UI blue (user messages)
S = 8                     # draw at 8x, then shrink for smooth edges
img = Image.new("RGB", (48 * S, 48 * S), (0, 0, 0))
d = ImageDraw.Draw(img)

def sc(*v): return [int(x * S) for x in v]

d.rounded_rectangle(sc(4, 6, 44, 34), radius=6 * S, fill=BLUE, outline=ORANGE, width=2 * S)
d.polygon([sc(11, 33)[:2], sc(11, 43)[:2], sc(21, 33)[:2]], fill=ORANGE)
d.polygon([sc(12.5, 32)[:2], sc(12.5, 39)[:2], sc(19, 32)[:2]], fill=BLUE)
# ">" and "_"
w = 3 * S
d.line(sc(14, 14, 22, 20, 14, 26), fill=ORANGE, width=w, joint="curve")
d.line(sc(25, 27.5, 34, 27.5), fill=ORANGE, width=w)
img = img.resize((48, 48), Image.LANCZOS)
img.save(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
