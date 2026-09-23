"""MCP image content helpers and a dependency-free PNG encoder."""

import base64
import os
import struct
import zlib

from .sdk import Image


def _image_content(path=None, data=None, fmt=None):
    """MCP image content (the SDK's Image helper) for a local file or raw bytes, or None
    when an image cannot be returned: no Image class, the file does not exist, or empty
    data. Tools that return images carry NO return annotation on purpose: the SDK emits
    mixed text + image content only for unannotated tools (a `-> str` tool returning a
    list fails output validation)."""
    if Image is None:
        return None
    try:
        if data:
            return Image(data=data, format=(fmt or "jpeg"))
        if path and os.path.isfile(path):
            return Image(path=path)
    except Exception:
        return None
    return None


def _maybe_with_image(text, image):
    """[text, image] when an image is available, otherwise just the text."""
    return [text, image] if image is not None else text


def _decode_base64_image(b64):
    """Bytes for a base64 image string from the bridge; b'' when it is missing or invalid."""
    if not b64 or not isinstance(b64, str):
        return b""
    try:
        return base64.b64decode(b64)
    except Exception:
        return b""


def _png_encode(width: int, height: int, rgb: bytearray) -> bytes:
    """A minimal PNG (8-bit RGB, no filtering) from a packed RGB buffer."""
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))
