#!/usr/bin/env python3
"""Render tmux ANSI capture files into terminal-style PNG frames.

Used by the screen-recording pipeline. Supports the subset of SGR escape
sequences emitted by a default bash/tmux setup (colors, bold, reset).
"""
import argparse
import os
import re

from PIL import Image, ImageDraw, ImageFont


# Standard ANSI 16-color palette (roughly xterm).
PALETTE = {
    30: (24, 24, 24), 31: (204, 59, 59), 32: (78, 162, 78),
    33: (196, 160, 52), 34: (64, 120, 196), 35: (150, 80, 160),
    36: (60, 150, 160), 37: (210, 210, 210),
    90: (110, 110, 110), 91: (230, 90, 90), 92: (110, 200, 110),
    93: (230, 200, 90), 94: (100, 150, 230), 95: (190, 120, 210),
    96: (100, 190, 200), 97: (235, 235, 235),
}
DEFAULT_FG = (212, 212, 212)
BG = (18, 20, 26)

SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")


def parse_line(line, state):
    """Yield (text, fg, bold) tuples for one physical line, updating state."""
    fg = state["fg"]
    bold = state["bold"]
    pos = 0
    out = []
    buf = ""
    for m in SGR_RE.finditer(line):
        buf += line[pos:m.start()]
        pos = m.end()
        if buf:
            out.append((buf, fg, bold))
            buf = ""
        params = m.group(1)
        codes = [int(p) if p else 0 for p in params.split(";")]
        for code in codes:
            if code == 0:
                fg = DEFAULT_FG
                bold = False
            elif code == 1:
                bold = True
            elif code == 22:
                bold = False
            elif code == 39:
                fg = DEFAULT_FG
            elif code in PALETTE:
                fg = PALETTE[code]
    buf += line[pos:]
    # strip any other escape sequences left over (cursor moves etc.)
    buf = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", buf)
    if buf:
        out.append((buf, fg, bold))
    state["fg"] = fg
    state["bold"] = bold
    return out


def render(cap_path, out_path, font_path, font_size=20, line_h=26,
           pad=24, title=None, canvas=(1760, 1180)):
    with open(cap_path, "r", encoding="utf-8", errors="replace") as fh:
        raw_lines = fh.read().split("\n")

    font = ImageFont.truetype(font_path, font_size)
    bold_font = ImageFont.truetype(font_path, font_size)

    # Measure geometry from the widest line (for text placement only).
    tmp = Image.new("RGB", (10, 10), BG)
    d = ImageDraw.Draw(tmp)
    max_w = 0
    for ln in raw_lines:
        clean = SGR_RE.sub("", ln)
        clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", clean)
        box = d.textbbox((0, 0), clean, font=font)
        max_w = max(max_w, box[2] - box[0])
    width, height = canvas
    title_h = 64 if title else 0

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)

    if title:
        draw.rectangle([0, 0, width, title_h], fill=(30, 42, 66))
        draw.text((pad, 16), title, font=bold_font, fill=(140, 190, 255))

    state = {"fg": DEFAULT_FG, "bold": False}
    y = pad + title_h
    for ln in raw_lines:
        x = pad
        for text, fg, bold in parse_line(ln, state):
            use_font = bold_font if bold else font
            draw.text((x, y), text, font=use_font, fill=fg)
            box = draw.textbbox((x, y), text, font=use_font)
            x = box[2]
        y += line_h

    img.save(out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cap")
    ap.add_argument("out")
    ap.add_argument("--font", default="/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf")
    ap.add_argument("--title", default=None)
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    render(args.cap, args.out, args.font, title=args.title)


if __name__ == "__main__":
    main()
