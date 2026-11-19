"""Platform permission checks that do not require a native SDK or signing key."""

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import scaffold_platforms


class AndroidScaffoldTest(unittest.TestCase):
    def test_https_query_coexists_with_flutter_text_query(self):
        template = (
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<queries><intent><action android:name="android.intent.action.PROCESS_TEXT"/>'
            '</intent></queries></manifest>'
        )
        output = scaffold_platforms.add_browser_query(template)
        self.assertIn('android.intent.action.PROCESS_TEXT', output)
        self.assertIn('android.intent.action.VIEW', output)
        self.assertEqual(output.count('<queries>'), 1)
        self.assertEqual(scaffold_platforms.add_browser_query(output), output)


class LinuxScaffoldTest(unittest.TestCase):
    def test_linux_uses_application_frame_after_regeneration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            generated = root / "template"
            runner = generated / "linux" / "runner" / "my_application.cc"
            runner.parent.mkdir(parents=True)
            runner.write_text(
                "  // Use a header bar when running in GNOME\n"
                "  gtk_window_set_titlebar(window, header);\n"
                "  gtk_window_set_default_size(window, 1280, 720);\n"
            )
            with (
                patch.object(scaffold_platforms, "ROOT", root),
                patch.object(scaffold_platforms, "generate",
                             return_value=generated),
                patch("sys.argv", ["scaffold_platforms.py", "linux"]),
            ):
                scaffold_platforms.main()
            output = root / "linux" / "runner" / runner.name
            patched = output.read_text()
            self.assertIn("gtk_window_set_decorated(window, FALSE);", patched)
            scaffold_platforms.patch_linux(root / "linux")
            self.assertEqual(output.read_text(), patched)


class MacosScaffoldTest(unittest.TestCase):
    def test_scaffold_grants_file_and_keychain_access_in_both_configurations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            generated = root / "generated"
            runner = generated / "macos" / "Runner"
            runner.mkdir(parents=True)
            originals = {
                "DebugProfile.entitlements": {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.cs.allow-jit": True,
                    "com.apple.security.network.server": True,
                },
                "Release.entitlements": {
                    "com.apple.security.app-sandbox": True,
                },
            }
            for name, values in originals.items():
                with (runner / name).open("wb") as destination:
                    plistlib.dump(values, destination)

            with (
                patch.object(scaffold_platforms, "ROOT", root),
                patch.object(scaffold_platforms, "generate", return_value=generated),
                patch("sys.argv", ["scaffold_platforms.py", "macos"]),
            ):
                scaffold_platforms.main()

            target = root / "macos"
            for name, original in originals.items():
                with self.subTest(configuration=name):
                    with (target / "Runner" / name).open("rb") as source:
                        values = plistlib.load(source)
                    for key, value in original.items():
                        self.assertEqual(values[key], value)
                    self.assertTrue(values["com.apple.security.network.client"])
                    self.assertTrue(
                        values["com.apple.security.files.user-selected.read-write"]
                    )
                    self.assertEqual(values["keychain-access-groups"], [])

            release = target / "Runner" / "Release.entitlements"
            with release.open("rb") as source:
                values = plistlib.load(source)
            values["keychain-access-groups"] = ["example.custom-group"]
            with release.open("wb") as destination:
                plistlib.dump(values, destination)
            scaffold_platforms.patch_macos(target)
            first = release.read_bytes()
            scaffold_platforms.patch_macos(target)
            self.assertEqual(release.read_bytes(), first)
            self.assertEqual(
                plistlib.loads(first)["keychain-access-groups"],
                ["example.custom-group"],
            )


if __name__ == "__main__":
    unittest.main()
