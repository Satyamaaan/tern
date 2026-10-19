#!/usr/bin/env python3
"""Local image server for the reader snapshot harness (ReaderSnapshot.swift).

Serves the remote images of the reader fixtures on 127.0.0.1:18766 and remembers every path it was asked
for: GET /__requests returns them as JSON, GET /__reset forgets them. Anything else is a 404, which the
failed-image fixture relies on. Standard library only; the PNGs are drawn here.

    python3 scripts/reader-image-server.py [port]
"""

import json
import struct
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def png(width, height, pixel):
    """A PNG of `pixel(x, y) -> (r, g, b, a)`."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


def inside_rounded(x, y, left, top, right, bottom, radius):
    if not (left <= x < right and top <= y < bottom):
        return False
    cx = min(max(x, left + radius), right - 1 - radius)
    cy = min(max(y, top + radius), bottom - 1 - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def logo_pixel(x, y):
    """500 x 120, shown at 250 x 60: a train mark in a rounded square and a blocky wordmark, on transparent."""
    ink = (24, 24, 27, 255)
    if inside_rounded(x, y, 4, 4, 116, 116, 26):
        if any(top <= y < top + 12 and 26 <= x < 94 for top in (34, 54, 74)):
            return (255, 255, 255, 255)
        return (124, 58, 237, 255)
    letters = [(140, 186), (196, 238), (248, 262), (272, 318), (328, 374), (384, 430), (440, 492)]
    for left, right in letters:
        if inside_rounded(x, y, left, 34, right, 92, 8) and not inside_rounded(x, y, left + 12, 46, right - 12, 80, 4):
            return ink
    return (0, 0, 0, 0)


def hero_pixel(x, y):
    """640 x 240: a teal-to-violet sweep with a soft sun."""
    t = x / 639
    r, g, b = int(20 + 104 * t), int(140 - 82 * t), int(150 + 87 * t)
    d = ((x - 470) ** 2 + (y - 90) ** 2) ** 0.5
    if d < 60:
        k = 1 - d / 60
        r, g, b = int(r + (255 - r) * k), int(g + (236 - g) * k), int(b + (200 - b) * k)
    return (r, g, b, 255)


def tile_pixel(x, y):
    return (238, 242, 255, 255) if (x // 10 + y // 10) % 2 else (224, 231, 255, 255)


IMAGES = {
    "/logo.png": png(500, 120, logo_pixel),
    "/hero.png": png(640, 240, hero_pixel),
    "/background.png": png(20, 20, tile_pixel),
    "/pixel.png": png(1, 1, lambda x, y: (0, 0, 0, 0)),
}
GIF_PIXEL = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"

requests = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/__requests":
            with lock:
                return self.answer(200, "application/json", json.dumps(requests).encode())
        if path == "/__reset":
            with lock:
                requests.clear()
            return self.answer(204, "text/plain", b"")
        with lock:
            requests.append(path)
        if path in IMAGES:
            return self.answer(200, "image/png", IMAGES[path], cache=True)
        if path.startswith("/e/o/"):
            return self.answer(200, "image/gif", GIF_PIXEL)
        return self.answer(404, "text/html", b"<html><body>Not found</body></html>")

    def answer(self, status, content_type, body, cache=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600" if cache else "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write("image server: %s\n" % (format % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18766
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
