import pathlib
import plistlib
import sys
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
