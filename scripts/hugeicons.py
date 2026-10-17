#!/usr/bin/env python3
"""Generates Tern's icon set from Hugeicons' free "Stroke Rounded" icons (MIT).

    python3 -I scripts/hugeicons.py <dir>/package/dist/esm [--sheet out.svg]

<dir> is the unpacked npm package @hugeicons/core-free-icons. Its modules are read as text and parsed
here; nothing from the package is executed. The script writes

- Sources/Tern/Shared/Hugeicons.swift: `enum Icon` with one case per entry in ICONS and each icon's
  drawing as absolute SVG path data on a 24x24 grid (circles, rects and lines become paths and
  transforms are applied, so the app's small parser only needs M L C Q A Z);
- the generated block between `// ICONS:BEGIN` and `// ICONS:END` in Resources/Web/reader.js;
- with --sheet, an SVG contact sheet of every icon for checking the choices by eye.

To add an icon, add a line to ICONS and run the script again.
"""

import math
import re
import sys
from pathlib import Path

PACKAGE_VERSION = "4.3.5"

# Tern name -> Hugeicons export name. Keep it sorted by area, as the app reads it.
ICONS = [
    # Mailboxes and tabs
    ("inbox", "InboxIcon"),
    ("needsReply", "MailReply01Icon"),
    ("snoozed", "Clock01Icon"),
    ("starred", "StarIcon"),
    ("drafts", "PencilEdit02Icon"),
    ("sent", "SentIcon"),
    ("allMail", "Mail01Icon"),
    ("spam", "SpamIcon"),
    ("trash", "Delete02Icon"),
    ("label", "Tag01Icon"),
    ("important", "Tag02Icon"),
    ("people", "UserIcon"),
    ("notification", "Notification01Icon"),
    ("newsletter", "Leaf01Icon"),
    ("receipt", "Invoice01Icon"),
    ("calendar", "Calendar03Icon"),
    ("promotion", "DiscountTag01Icon"),
    ("security", "Shield01Icon"),
    ("other", "MoreHorizontalCircle01Icon"),
    ("folder", "Folder01Icon"),
    ("savedSearch", "Search02Icon"),
    # Project icons (stored as SF Symbol names; see Icon.project)
    ("paperplane", "SentIcon"),
    ("palette", "PaintBoardIcon"),
    ("house", "Home01Icon"),
    ("briefcase", "Briefcase01Icon"),
    ("hammer", "HammerIcon"),
    ("book", "Book02Icon"),
    ("heart", "FavouriteIcon"),
    ("airplane", "Airplane01Icon"),
    ("cart", "ShoppingCart01Icon"),
    ("graduation", "Mortarboard01Icon"),
    # Actions
    ("compose", "PencilEdit01Icon"),
    ("search", "Search01Icon"),
    ("done", "Tick02Icon"),
    ("archive", "Archive02Icon"),
    ("ellipsis", "MoreHorizontalIcon"),
    ("plus", "Add01Icon"),
    ("close", "Cancel01Icon"),
    ("reply", "ArrowTurnBackwardIcon"),
    ("replyAll", "MailReplyAll01Icon"),
    ("forward", "ArrowTurnForwardIcon"),
    ("star", "StarIcon"),
    ("mute", "NotificationOff01Icon"),
    ("unread", "MailOpen01Icon"),
    ("print", "PrinterIcon"),
    ("undo", "Undo02Icon"),
    ("sparkles", "SparklesIcon"),
    ("send", "SentIcon"),
    ("copy", "Copy01Icon"),
    ("external", "LinkSquare02Icon"),
    ("eye", "ViewIcon"),
    ("download", "Download01Icon"),
    ("refresh", "Refresh01Icon"),
    # Chevrons and arrows
    ("chevronDown", "ArrowDown01Icon"),
    ("chevronUp", "ArrowUp01Icon"),
    ("chevronLeft", "ArrowLeft01Icon"),
    ("chevronRight", "ArrowRight01Icon"),
    ("back", "ArrowLeft02Icon"),
    # Window
    ("sidebar", "SidebarLeft01Icon"),
    ("readingPane", "SidebarRight01Icon"),
    ("settings", "Settings01Icon"),
    ("sun", "Sun03Icon"),
    ("moon", "Moon02Icon"),
    ("command", "CommandIcon"),
    ("keyboard", "KeyboardIcon"),
    # Files and formatting
    ("paperclip", "Attachment01Icon"),
    ("file", "File02Icon"),
    ("image", "Image01Icon"),
    ("video", "Video01Icon"),
    ("audio", "MusicNote01Icon"),
    ("zip", "FileZipIcon"),
    ("link", "Link01Icon"),
    ("bold", "TextBoldIcon"),
    ("italic", "TextItalicIcon"),
    ("underline", "TextUnderlineIcon"),
    ("listBullet", "LeftToRightListBulletIcon"),
    ("listNumber", "LeftToRightListNumberIcon"),
    ("quote", "QuoteDownIcon"),
    # Settings and status
    ("person", "UserIcon"),
    ("at", "AtIcon"),
    ("key", "Key01Icon"),
    ("paint", "PaintBoardIcon"),
    ("sliders", "SlidersHorizontalIcon"),
    ("warning", "Alert02Icon"),
    ("info", "InformationCircleIcon"),
]

# Icons the reader page draws itself (attachment chips, the details disclosure, the AI line).
WEB_ICONS = [("file", "ICON_FILE"), ("image", "ICON_IMAGE"), ("chevronDown", "ICON_CHEVRON"), ("sparkles", "ICON_SPARK")]

ROOT = Path(__file__).resolve().parent.parent

# MARK: Reading the modules


def parse_module(text):
    """[(tag, {attr: value})] from a module of the form `const X = [["path", { d: "…", … }], …];`."""
    elements = []
    for tag, body in re.findall(r'\[\s*"(\w+)"\s*,\s*\{(.*?)\}\s*\]', text, re.S):
        attrs = dict(re.findall(r'(\w+)\s*:\s*"([^"]*)"', body))
        elements.append((tag, attrs))
    if not elements:
        raise ValueError("no elements found")
    return elements


# MARK: Path data

TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def tokens(d):
    return TOKEN.findall(d)


def absolute(d):
    """Path data -> [(cmd, args)] with only absolute M L C Q A Z."""
    out = []
    items = tokens(d)
    i = 0
    cmd = None
    cx = cy = sx = sy = 0.0
    last_c = last_q = None

    def num():
        nonlocal i
        value = float(items[i])
        i += 1
        return value

    while i < len(items):
        if re.match(r"[A-Za-z]", items[i]):
            cmd = items[i]
            i += 1
            if cmd in "Zz":
                out.append(("Z", []))
                cx, cy = sx, sy
                last_c = last_q = None
                continue
        rel = cmd.islower()
        c = cmd.upper()
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        if c == "M":
            cx, cy = num() + ox, num() + oy
            sx, sy = cx, cy
            out.append(("M", [cx, cy]))
            cmd = "l" if rel else "L"
            last_c = last_q = None
        elif c == "L":
            cx, cy = num() + ox, num() + oy
            out.append(("L", [cx, cy]))
            last_c = last_q = None
        elif c == "H":
            cx = num() + (cx if rel else 0.0)
            out.append(("L", [cx, cy]))
            last_c = last_q = None
        elif c == "V":
            cy = num() + (cy if rel else 0.0)
            out.append(("L", [cx, cy]))
            last_c = last_q = None
        elif c == "C":
            x1, y1, x2, y2, x, y = num() + ox, num() + oy, num() + ox, num() + oy, num() + ox, num() + oy
            out.append(("C", [x1, y1, x2, y2, x, y]))
            last_c, last_q = (x2, y2), None
            cx, cy = x, y
        elif c == "S":
            x1, y1 = (2 * cx - last_c[0], 2 * cy - last_c[1]) if last_c else (cx, cy)
            x2, y2, x, y = num() + ox, num() + oy, num() + ox, num() + oy
            out.append(("C", [x1, y1, x2, y2, x, y]))
            last_c, last_q = (x2, y2), None
            cx, cy = x, y
        elif c == "Q":
            x1, y1, x, y = num() + ox, num() + oy, num() + ox, num() + oy
            out.append(("Q", [x1, y1, x, y]))
            last_q, last_c = (x1, y1), None
            cx, cy = x, y
        elif c == "T":
            x1, y1 = (2 * cx - last_q[0], 2 * cy - last_q[1]) if last_q else (cx, cy)
            x, y = num() + ox, num() + oy
            out.append(("Q", [x1, y1, x, y]))
            last_q, last_c = (x1, y1), None
            cx, cy = x, y
        elif c == "A":
            rx, ry, rot = num(), num(), num()
            large, sweep = num(), num()
            x, y = num() + ox, num() + oy
            out.append(("A", [rx, ry, rot, large, sweep, x, y]))
            cx, cy = x, y
            last_c = last_q = None
        else:
            raise ValueError(f"unsupported command {cmd}")
    return out


def circle(cx, cy, rx, ry=None):
    ry = rx if ry is None else ry
    return [("M", [cx - rx, cy]), ("A", [rx, ry, 0, 1, 0, cx + rx, cy]), ("A", [rx, ry, 0, 1, 0, cx - rx, cy]), ("Z", [])]


def rect(x, y, w, h, rx, ry):
    if rx == 0 and ry == 0:
        return [("M", [x, y]), ("L", [x + w, y]), ("L", [x + w, y + h]), ("L", [x, y + h]), ("Z", [])]
    rx, ry = min(rx, w / 2), min(ry, h / 2)
    return [
        ("M", [x + rx, y]), ("L", [x + w - rx, y]), ("A", [rx, ry, 0, 0, 1, x + w, y + ry]),
        ("L", [x + w, y + h - ry]), ("A", [rx, ry, 0, 0, 1, x + w - rx, y + h]),
        ("L", [x + rx, y + h]), ("A", [rx, ry, 0, 0, 1, x, y + h - ry]),
        ("L", [x, y + ry]), ("A", [rx, ry, 0, 0, 1, x + rx, y]), ("Z", []),
    ]


def points(text):
    values = [float(v) for v in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", text)]
    return list(zip(values[0::2], values[1::2]))


def element_path(tag, a):
    f = lambda key, default=0.0: float(a.get(key, default))
    if tag == "path":
        return absolute(a["d"])
    if tag == "circle":
        return circle(f("cx"), f("cy"), f("r"))
    if tag == "ellipse":
        return circle(f("cx"), f("cy"), f("rx"), f("ry"))
    if tag == "rect":
        rx = f("rx", a.get("ry", 0))
        ry = f("ry", a.get("rx", 0))
        return rect(f("x"), f("y"), f("width"), f("height"), rx, ry)
    if tag == "line":
        return [("M", [f("x1"), f("y1")]), ("L", [f("x2"), f("y2")])]
    if tag in ("polyline", "polygon"):
        pts = points(a["points"])
        path = [("M", list(pts[0]))] + [("L", list(p)) for p in pts[1:]]
        return path + ([("Z", [])] if tag == "polygon" else [])
    raise ValueError(f"unsupported element {tag}")


# MARK: Transforms


def parse_transform(text):
    m = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", text):
        v = [float(x) for x in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", args)]
        if name == "matrix":
            t = v
        elif name == "translate":
            t = [1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0]
        elif name == "scale":
            t = [v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0]
        elif name == "rotate":
            r = math.radians(v[0])
            cx, cy = (v[1], v[2]) if len(v) > 2 else (0, 0)
            c, s = math.cos(r), math.sin(r)
            t = [c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy]
        else:
            raise ValueError(f"unsupported transform {name}")
        m = multiply(m, t)
    return m


def multiply(m, t):
    a, b, c, d, e, f = m
    a2, b2, c2, d2, e2, f2 = t
    return [a * a2 + c * b2, b * a2 + d * b2, a * c2 + c * d2, b * c2 + d * d2, a * e2 + c * f2 + e, b * e2 + d * f2 + f]


def apply(m, path):
    a, b, c, d, e, f = m
    pt = lambda x, y: [a * x + c * y + e, b * x + d * y + f]
    det = a * d - b * c
    scale_x, scale_y = math.hypot(a, b), math.hypot(c, d)
    if abs(scale_x - scale_y) > 1e-6 or abs(a * c + b * d) > 1e-6:
        if any(cmd == "A" for cmd, _ in path):
            raise ValueError("arcs under a non-uniform transform")
    rotation = math.degrees(math.atan2(b, a))
    out = []
    for cmd, v in path:
        if cmd in ("M", "L"):
            out.append((cmd, pt(*v)))
        elif cmd == "C":
            out.append((cmd, pt(v[0], v[1]) + pt(v[2], v[3]) + pt(v[4], v[5])))
        elif cmd == "Q":
            out.append((cmd, pt(v[0], v[1]) + pt(v[2], v[3])))
        elif cmd == "A":
            rx, ry, rot, large, sweep, x, y = v
            out.append(("A", [rx * scale_x, ry * scale_x, rot + rotation, large, (1 - sweep) if det < 0 else sweep] + pt(x, y)))
        else:
            out.append((cmd, v))
    return out


# MARK: Output


def fmt(value):
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def path_data(path):
    return " ".join(cmd + (" " + " ".join(fmt(x) for x in v) if v else "") for cmd, v in path)


def load(esm, name):
    parts = []
    for tag, attrs in parse_module((esm / f"{name}.js").read_text()):
        path = element_path(tag, attrs)
        if "transform" in attrs:
            path = apply(parse_transform(attrs["transform"]), path)
        stroked = attrs.get("stroke", "none") != "none"
        filled = attrs.get("fill", "none") not in ("none", "")
        if "opacity" in attrs or "fillOpacity" in attrs:
            print(f"warning: {name} uses opacity; drawn opaque", file=sys.stderr)
        width = float(attrs.get("strokeWidth", "1.5")) if stroked else 0.0
        parts.append((path_data(path), width, filled))
    return parts


def swift(icons):
    lines = [
        f"// Generated by scripts/hugeicons.py from @hugeicons/core-free-icons {PACKAGE_VERSION}",
        "// (Hugeicons \"Stroke Rounded\", MIT, see Resources/Licenses). Do not edit; change the script.",
        "",
        "import CoreGraphics",
        "",
        "/// Tern's icons: Hugeicons Stroke Rounded on a 24×24 grid, drawn with round caps and joins.",
        "enum Icon: String, CaseIterable, Sendable {",
    ]
    for tern, _ in ICONS:
        lines.append(f"    case {tern}")
    lines += [
        "",
        "    /// The drawing: absolute SVG path data, stroke width on the 24 grid (0 = not stroked), filled.",
        "    var parts: [IconPart] {",
        "        switch self {",
    ]
    for tern, hugeicon in ICONS:
        lines.append(f"        case .{tern}: // {hugeicon}")
        lines.append("            [")
        for data, width, filled in icons[tern]:
            lines.append(f'                IconPart("{data}", stroke: {fmt(width)}{", filled: true" if filled else ""}),')
        lines.append("            ]")
    lines += ["        }", "    }", "}", ""]
    return "\n".join(lines)


def svg_markup(parts, size=None):
    body = ""
    for data, width, filled in parts:
        fill = "currentColor" if filled else "none"
        stroke = f' stroke="currentColor" stroke-width="{fmt(width)}"' if width > 0 else ""
        body += f'<path d="{data}" fill="{fill}"{stroke}/>'
    dims = f' width="{size}" height="{size}"' if size else ""
    return f'<svg viewBox="0 0 24 24"{dims} stroke-linecap="round" stroke-linejoin="round">{body}</svg>'


def write_web(icons):
    script = ROOT / "Resources/Web/reader.js"
    text = script.read_text()
    block = ["  // ICONS:BEGIN generated by scripts/hugeicons.py (Hugeicons Stroke Rounded, MIT)"]
    for tern, const in WEB_ICONS:
        block.append(f"  const {const} = '{svg_markup(icons[tern])}';")
    block.append("  // ICONS:END")
    new, count = re.subn(r"  // ICONS:BEGIN.*?// ICONS:END", "\n".join(block), text, flags=re.S)
    if count != 1:
        raise SystemExit("reader.js has no // ICONS:BEGIN … // ICONS:END block")
    script.write_text(new)


def write_sheet(icons, out):
    cell, columns = 76, 10
    rows = (len(ICONS) + columns - 1) // columns
    body = ""
    for index, (tern, hugeicon) in enumerate(ICONS):
        x, y = (index % columns) * cell, (index // columns) * cell
        inner = svg_markup(icons[tern]).replace("<svg ", f'<svg x="{x + 20}" y="{y + 8}" width="36" height="36" ')
        body += f'<g color="#161616">{inner}</g><text x="{x + cell / 2}" y="{y + 62}" font-size="9" text-anchor="middle" font-family="Helvetica" fill="#74746E">{tern}</text>'
    out.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{columns * cell}" height="{rows * cell}"><rect width="100%" height="100%" fill="#fff"/>{body}</svg>')


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    esm = Path(sys.argv[1])
    icons = {tern: load(esm, hugeicon) for tern, hugeicon in ICONS}
    (ROOT / "Sources/Tern/Shared/Hugeicons.swift").write_text(swift(icons))
    write_web(icons)
    if "--sheet" in sys.argv:
        write_sheet(icons, Path(sys.argv[sys.argv.index("--sheet") + 1]))
    print(f"{len(ICONS)} icons written")


if __name__ == "__main__":
    main()
