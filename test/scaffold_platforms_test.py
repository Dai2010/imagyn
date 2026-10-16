"""Platform permission checks that do not require a native SDK or signing key."""

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import scaffold_platforms


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
