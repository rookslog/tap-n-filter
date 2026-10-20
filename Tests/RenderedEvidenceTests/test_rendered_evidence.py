"""CI artifact contract; reads files only, never launches the app or renderer.

Run from the package root with python3 Tests/RenderedEvidenceTests/test_rendered_evidence.py.
TNF_RENDERED_EVIDENCE_DIR may point at a downloaded artifact directory. The
exporter must emit manifest.json with source/environment/limits objects and an
images array. Required field names and observable values are specified below.
This is evidence validation, not a golden-image comparison or visual approval.
"""

import hashlib
import json
import math
import os
from pathlib import Path
import struct
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = Path(os.environ.get(
    "TNF_RENDERED_EVIDENCE_DIR", ROOT / "test-artifacts/rendered-evidence"
))
STATES = ("idle", "running", "multiline-error", "expanded-eq", "settings-open")
THEMES = ("light", "dark")
EXPECTED = {
    f"control-panel-{state}-{theme}.png": (state, theme)
    for state in STATES for theme in THEMES
}


def decode_png(data, require_opaque=False):
    """Decode bounded noninterlaced 8-bit RGB/RGBA evidence, including filters.

    The native exporter should normalize its bitmap to this first-party PNG
    format. Inspect decoded content, not compressed bytes or IHDR alone.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("Missing PNG signature")
    offset, compressed, header, ended = 8, bytearray(), None, False
    while offset < len(data):
        if offset + 12 > len(data):
            raise AssertionError("Truncated PNG chunk")
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if offset + length + 12 > len(data):
            raise AssertionError("Truncated PNG payload")
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise AssertionError("Invalid PNG CRC")
        if header is None and kind != b"IHDR":
            raise AssertionError("IHDR must be first")
        if kind == b"IHDR":
            if header is not None or length != 13:
                raise AssertionError("Invalid IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            ended = length == 0
            offset += length + 12
            break
        offset += length + 12
    if not ended or offset != len(data) or header is None:
        raise AssertionError("Missing IEND or trailing PNG bytes")
    width, height, depth, color, compression, filtering, interlace = header
    if not (0 < width <= 1520 and 0 < height <= 3600):
        raise AssertionError("Invalid or unbounded decoded dimensions")
    if depth != 8 or color not in (2, 6) or (compression, filtering, interlace) != (0, 0, 0):
        raise AssertionError("Expected noninterlaced 8-bit RGB/RGBA PNG")
    channels = 3 if color == 2 else 4
    stride = width * channels
    expected_bytes = height * (stride + 1)
    decoder = zlib.decompressobj()
    raw = decoder.decompress(bytes(compressed), expected_bytes + 1)
    if len(raw) != expected_bytes or not decoder.eof or decoder.unused_data:
        raise AssertionError("PNG scanline payload does not match dimensions")
    previous = bytearray(stride)
    pixels = bytearray()
    for y in range(height):
        start = y * (stride + 1)
        mode = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if mode > 4:
            raise AssertionError("Invalid PNG filter")
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if mode == 1:
                predictor = left
            elif mode == 2:
                predictor = above
            elif mode == 3:
                predictor = (left + above) // 2
            elif mode == 4:
                p = left + above - upper_left
                distances = (abs(p - left), abs(p - above), abs(p - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        for x in range(0, stride, channels):
            alpha = row[x + 3] if channels == 4 else 255
            if require_opaque and alpha != 255:
                raise AssertionError("Presentation PNG contains transparent pixels")
            # Composite onto white so invisible RGB noise cannot count as UI.
            pixels.extend((c * alpha + 255 * (255 - alpha)) // 255 for c in row[x:x + 3])
        previous = row
    return width, height, bytes(pixels)


class PNGDecoderTests(unittest.TestCase):
    """Synthetic bytes exercise the evidence oracle, never stand in for UI PNGs."""

    @staticmethod
    def png(raw, color=2):
        def chunk(kind, payload):
            return (
                struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
            )
        header = struct.pack(">IIBBBBB", 2, 2, 8, color, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        )

    def test_all_rgb_filter_modes_decode_known_pixels(self):
        first = bytes([0, 10, 20, 30, 40, 50, 60])
        expected = bytes([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
        # Hand-calculated residuals for the same second row, not an encoder
        # reimplementing the decoder's predictor calculations.
        for row in (
            [0, 70, 80, 90, 100, 110, 120],
            [1, 70, 80, 90, 30, 30, 30],
            [2, 60, 60, 60, 60, 60, 60],
            [3, 65, 70, 75, 45, 45, 45],
            [4, 60, 60, 60, 30, 30, 30],
        ):
            with self.subTest(filter=row[0]):
                self.assertEqual(decode_png(self.png(first + bytes(row))), (2, 2, expected))

    def test_transparent_rgba_noise_decodes_to_solid_white(self):
        raw = bytes([0, 1, 2, 3, 0, 4, 5, 6, 0] * 2)
        self.assertEqual(decode_png(self.png(raw, color=6)), (2, 2, bytes([255] * 12)))

    def test_opaque_presentation_check_rejects_transparency_without_changing_default_decode(self):
        transparent = bytes([0, 1, 2, 3, 0, 4, 5, 6, 0] * 2)
        with self.assertRaisesRegex(AssertionError, "transparent pixels"):
            decode_png(self.png(transparent, color=6), require_opaque=True)
        opaque = bytes([0, 1, 2, 3, 255, 4, 5, 6, 255] * 2)
        expected = bytes([1, 2, 3, 4, 5, 6] * 2)
        self.assertEqual(decode_png(self.png(opaque, color=6), require_opaque=True), (2, 2, expected))

    def test_bad_signature_truncation_crc_and_trailing_bytes_are_rejected(self):
        valid = self.png(bytes([0, 10, 20, 30, 40, 50, 60] * 2))
        for data in (
            b"bad", valid[:-1], valid[:29] + bytes([valid[29] ^ 1]) + valid[30:], valid + b"trailing",
        ):
            with self.subTest(data_length=len(data)):
                with self.assertRaises(AssertionError):
                    decode_png(data)


class RenderedEvidenceArtifactTests(unittest.TestCase):
    def manifest(self):
        path = ARTIFACTS / "manifest.json"
        self.assertTrue(path.is_file(), f"Missing rendered-evidence manifest: {path}")
        document = json.loads(path.read_text())
        self.assertEqual(document["schemaVersion"], 1)
        return document

    def test_manifest_and_directory_contain_exactly_the_ten_expected_images(self):
        images = self.manifest()["images"]
        self.assertEqual(len(images), 10)
        self.assertEqual({image["file"] for image in images}, set(EXPECTED))
        self.assertEqual({path.name for path in ARTIFACTS.glob("*.png")}, set(EXPECTED))
        for image in images:
            self.assertEqual((image["state"], image["theme"]), EXPECTED[image["file"]])

    def test_manifest_records_checkout_and_pr_head_separately_with_environment(self):
        manifest = self.manifest()
        source = manifest["source"]
        self.assertRegex(source["checkoutSHA"], r"^[0-9a-f]{40}$")
        self.assertTrue(source["eventName"].strip())
        self.assertTrue(source["ref"].strip())
        for field in ("prHeadSHA", "baseSHA"):
            value = source[field]
            if source["eventName"] == "pull_request" or value is not None:
                self.assertRegex(value, r"^[0-9a-f]{40}$", field)
        if source["eventName"] == "pull_request" or source["baseRef"] is not None:
            self.assertTrue(source["baseRef"].strip())
        # A synthetic merge checkout is allowed to differ from the PR head.
        # CI supplies these separately; never infer one from the other.
        for field, env_key in (("checkoutSHA", "TNF_CHECKOUT_SHA"), ("prHeadSHA", "TNF_PR_HEAD_SHA")):
            if env_key in os.environ:
                self.assertEqual(source[field], os.environ[env_key])
        for field in ("macOS", "swift", "xcode"):
            self.assertTrue(manifest["environment"][field].strip(), field)

    def test_manifest_declares_fake_only_materialization_limits(self):
        limits = self.manifest()["limits"]
        for field, expected in (
            ("fakeCapture", True), ("isolatedDefaults", True), ("audioStarted", False),
            ("actualMenuBarExtra", False), ("manualLayoutGateSatisfied", False),
        ):
            self.assertIs(limits[field], expected, field)

    def test_observed_state_at_render_matches_label_and_preserves_view_identity(self):
        for image in self.manifest()["images"]:
            with self.subTest(file=image["file"]):
                state = image["state"]
                observed = image["observed"]
                self.assertTrue(image["preparedViewIdentity"])
                self.assertEqual(image["preparedViewIdentity"], image["renderedViewIdentity"])
                capture_state = {"running": "running", "multiline-error": "failed"}.get(state, "idle")
                self.assertEqual(observed["captureState"], capture_state)
                self.assertIs(observed["engineRunning"], False)
                self.assertIs(observed["showSettings"], state == "settings-open")
                self.assertIs(observed["showDebugPanel"], False)
                if state == "expanded-eq":
                    self.assertTrue(observed["expandedEffectID"])
                    self.assertEqual(observed["expandedEffectType"], "tnf.eq")
                    self.assertEqual(observed["expandedEffectID"], observed["eqNodeID"])
                else:
                    self.assertIsNone(observed["expandedEffectID"])
                if state == "multiline-error":
                    self.assertGreaterEqual(len(observed["errorMessage"].splitlines()), 2)
                else:
                    self.assertIsNone(observed["errorMessage"])
                if state == "running":
                    self.assertTrue(observed["sourceDisplayName"])

    def test_pngs_decode_at_measured_height_are_nonblank_and_not_relabelled_idle(self):
        digests = {theme: set() for theme in THEMES}
        for image in self.manifest()["images"]:
            with self.subTest(file=image["file"]):
                self.assertIn(image["file"], EXPECTED)
                data = (ARTIFACTS / image["file"]).read_bytes()
                self.assertGreater(len(data), 100)
                width, height, pixels = decode_png(data)
                self.assertEqual(image["widthPoints"], 380)
                fitting = image["fittingHeightPoints"]
                self.assertTrue(math.isfinite(fitting))
                self.assertGreaterEqual(fitting, 420)
                self.assertLessEqual(fitting, 900 if image["state"] == "settings-open" else 700)
                scale = image["scale"]
                self.assertIn(scale, (1, 2))
                self.assertEqual((width, height), (image["pixelWidth"], image["pixelHeight"]))
                self.assertEqual(width, 380 * scale)
                self.assertLessEqual(abs(height - fitting * scale), 1)
                colors = {pixels[i:i + 3] for i in range(0, len(pixels), 3)}
                self.assertGreater(len(colors), 8, "Blank/solid-color image is not panel evidence")
                digest = hashlib.sha256(pixels).digest()
                self.assertNotIn(digest, digests[image["theme"]], "Same decoded pixels under another state label")
                digests[image["theme"]].add(digest)

    def test_presentation_is_opaque_with_explicit_matching_theme_background(self):
        for image in self.manifest()["images"]:
            with self.subTest(file=image["file"]):
                self.assertIn(image["file"], EXPECTED)
                shade = 1 if image["theme"] == "light" else 0.12
                self.assertEqual(image["backgroundRGB"], [shade] * 3)
                self.assertIn("Opaque sRGB", image["presentation"])
                _, _, pixels = decode_png(
                    (ARTIFACTS / image["file"]).read_bytes(), require_opaque=True
                )
                # The unrounded panel's corner is background, outside padded
                # controls. This checks the declared compositing color, not a
                # screenshot baseline; allow two 8-bit levels for conversion.
                for channel in pixels[:3]:
                    self.assertLessEqual(abs(channel - round(shade * 255)), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
