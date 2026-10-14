import pathlib
import plistlib
import sys
import struct
import unittest

ROOT = pathlib.Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / 'Resources'))
import semantic_search


class BrandingTests(unittest.TestCase):
    def test_display_and_executable_renamed_with_durable_bundle_identity(self):
        with (ROOT / 'Resources/Info.plist').open('rb') as file:
            info = plistlib.load(file)
        for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable'):
            self.assertEqual(info[key], 'Backtrace')
        self.assertEqual(info['CFBundleIdentifier'], 'com.jacobsapps.Backtrack')
        self.assertEqual(semantic_search.ROOT, pathlib.Path.home() / 'Library/Application Support/Backtrack')

    def test_package_and_app_sources_use_new_name(self):
        manifest = (ROOT / 'Package.swift').read_text()
        self.assertIn('.executable(name: "Backtrace", targets: ["Backtrace"])', manifest)
        self.assertTrue((ROOT / 'Sources/Backtrace/App.swift').exists())
        self.assertTrue((ROOT / 'Sources/BacktraceCore/LocalSearch.swift').exists())
        self.assertTrue((ROOT / 'Resources/Backtrace.entitlements').exists())

    def test_icon_has_small_and_retina_representations(self):
        data = (ROOT / 'Resources/AppIcon.icns').read_bytes()
        self.assertEqual(data[:4], b'icns')
        self.assertEqual(struct.unpack('>I', data[4:8])[0], len(data))
        types = set()
        offset = 8
        while offset < len(data):
            kind, length = struct.unpack('>4sI', data[offset:offset + 8])
            self.assertGreaterEqual(length, 8)
            self.assertLessEqual(offset + length, len(data))
            types.add(kind)
            offset += length
        self.assertEqual(offset, len(data))
        # The former lockFocus renderer accidentally emitted double-size images
        # on Retina hosts, so the 16 px / 32 px representations were missing.
        self.assertTrue({b'ic04', b'ic05', b'ic07', b'ic08', b'ic09',
                         b'ic10', b'ic11', b'ic12', b'ic13', b'ic14'} <= types)
        png = (ROOT / 'Resources/AppIcon.png').read_bytes()
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>II', png[16:24]), (1024, 1024))
