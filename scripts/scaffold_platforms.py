#!/usr/bin/env python3
"""Generate the Flutter platform folders that this repository does not track.

`android/`, `linux/`, `windows/` and `macos/` are produced by `flutter create`
and stay out of git (see .gitignore): they are mostly boilerplate that has to
match the installed Flutter version, so regenerating them is more reliable than
keeping a stale copy. This script regenerates them and then copies the files
this app actually owns from `platform/` on top.

    python3 scripts/scaffold_platforms.py [platforms] [--release-signing]

`platforms` defaults to `android,linux,windows,macos`.

Anything under `platform/<platform>/` mirrors the layout inside the generated
`<platform>/` folder, so the overlay is a plain file-for-file copy. Files we own
today: the Android media-save channel and the app's display name.

`--release-signing` additionally wires the Android release build to a keystore
described by `android/key.properties` (the file itself is never committed). It
is used by the release workflow only; without it the generated template keeps
signing release builds with the throwaway debug key, which is what the build
workflow wants for its test artifacts.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PLATFORMS = "android,linux,windows,macos"
DEFAULT_PLATFORM_LIST = ["android", "linux", "windows", "macos"]

# RELATIVE_PATH on MediaStore needs API 29; the media-save channel relies on it.
ANDROID_MIN_SDK = 29

SIGNING_CONFIGS_KTS = """    signingConfigs {
        create("release") {
            val properties = java.util.Properties()
            val keyFile = rootProject.file("key.properties")
            if (keyFile.exists()) {
                keyFile.inputStream().use { properties.load(it) }
            }
            storeFile = properties.getProperty("storeFile")?.let { rootProject.file(it) }
            storePassword = properties.getProperty("storePassword")
            keyAlias = properties.getProperty("keyAlias")
            keyPassword = properties.getProperty("keyPassword")
        }
    }

"""

SIGNING_CONFIGS_GROOVY = """    signingConfigs {
        release {
            def properties = new Properties()
            def keyFile = rootProject.file('key.properties')
            if (keyFile.exists()) {
                keyFile.withInputStream { properties.load(it) }
            }
            storeFile properties.getProperty('storeFile') ? rootProject.file(properties.getProperty('storeFile')) : null
            storePassword properties.getProperty('storePassword')
            keyAlias properties.getProperty('keyAlias')
            keyPassword properties.getProperty('keyPassword')
        }
    }

"""


def fail(message: str) -> None:
    sys.exit(f"scaffold_platforms: {message}")


def run(command: list[str]) -> None:
    print("+", " ".join(command))
    subprocess.run(command, check=True)


def flutter_command() -> list[str]:
    """The command that launches the Flutter tool on this platform.

    On Windows the SDK ships `flutter.bat`, which subprocess cannot execute
    directly — it has to be handed to cmd.exe, or Windows raises
    FileNotFoundError.
    """
    exe = shutil.which("flutter")
    if exe is None:
        fail("flutter is not on PATH; install the Flutter SDK first")
    if os.name == "nt":
        return ["cmd", "/c", exe]
    return [exe]


def generate(platforms: list[str], workdir: Path) -> Path:
    generated = workdir / "scaffold"
    run(flutter_command() + [
        "create",
        "--platforms", ",".join(platforms),
        "--org", "app",
        "--project-name", "imagyn",
        str(generated),
    ])
    return generated


def copy_overlay(platform: str, target: Path) -> list[str]:
    source = ROOT / "platform" / platform
    copied: list[str] = []
    if not source.is_dir():
        return copied
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(source)
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        copied.append(str(relative))
    return copied


def patch_android(target: Path, release_signing: bool) -> None:
    gradle = sorted(target.glob("app/build.gradle*"))
    gradle = [path for path in gradle if path.suffix in {".kts", ".gradle"}]
    if len(gradle) != 1:
        fail(f"expected exactly one app/build.gradle(.kts) under {target}, found {len(gradle)}")
    gradle_file = gradle[0]
    text = gradle_file.read_text()

    text, groovy = re.subn(r"minSdkVersion\s+flutter\.minSdkVersion",
                           f"minSdkVersion {ANDROID_MIN_SDK}", text)
    text, kotlin = re.subn(r"minSdk\s*=\s*flutter\.minSdkVersion",
                           f"minSdk = {ANDROID_MIN_SDK}", text)
    if groovy + kotlin != 1:
        fail(f"could not find the minSdk setting in {gradle_file.name}; "
             "the Flutter template changed, update this script")

    manifest = target / "app/src/main/AndroidManifest.xml"
    if not manifest.is_file():
        fail(f"{manifest} is missing")
    manifest_text = manifest.read_text()
    manifest_text, labelled = re.subn(r'android:label="[^"]*"',
                                      'android:label="@string/app_name"', manifest_text, count=1)
    if labelled != 1:
        fail("could not find android:label in AndroidManifest.xml; "
             "the Flutter template changed, update this script")

    # The Flutter template declares INTERNET only in the debug and profile
    # manifests, where the tooling needs it for hot reload; a release build reads
    # the main manifest alone. Without this line the shipped APK has no network
    # access at all — every request fails with "Failed host lookup" while the
    # phone's own resolver reaches the same host without trouble.
    if "android.permission.INTERNET" not in manifest_text:
        anchor = "<application"
        if anchor not in manifest_text:
            fail("could not find <application in AndroidManifest.xml; "
                 "the Flutter template changed, update this script")
        # `str.replace` takes no keyword arguments (`re.subn` above does take
        # `count=`; that difference is what reddened the first attempt).
        manifest_text = manifest_text.replace(
            anchor,
            '    <uses-permission android:name="android.permission.INTERNET" />\n' + anchor)
    manifest.write_text(manifest_text)

    # Only one MainActivity may exist: ours replaces the generated one, and any
    # leftover in the other source root would collide with it.
    keep = (target / "app/src/main/kotlin/app/imagyn/MainActivity.kt").resolve()
    for leftover in target.rglob("MainActivity.kt"):
        if leftover.resolve() != keep:
            print("- removing generated", leftover.relative_to(target))
            leftover.unlink()

    if release_signing:
        kts = gradle_file.suffix == ".kts"
        block = SIGNING_CONFIGS_KTS if kts else SIGNING_CONFIGS_GROOVY
        anchor = "    buildTypes {"
        if anchor not in text:
            fail(f"could not find `{anchor.strip()}` in {gradle_file.name}; "
                 "the Flutter template changed, update this script")
        text = text.replace(anchor, block + anchor, 1)
        if kts:
            text, wired = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                                  'signingConfig = signingConfigs.getByName("release")', text)
        else:
            text, wired = re.subn(r"signingConfig\s+signingConfigs\.debug",
                                  "signingConfig signingConfigs.release", text)
        if wired != 1:
            fail(f"could not point the release build type at the release keystore in "
                 f"{gradle_file.name}; the Flutter template changed, update this script")
        print("+ release builds now require android/key.properties")

    gradle_file.write_text(text)


def patch_macos(target: Path) -> None:
    for entitlements in (target / "Runner").glob("*.entitlements"):
        with entitlements.open("rb") as source:
            values = plistlib.load(source)
        values["com.apple.security.network.client"] = True
        # file_selector needs read/write access for importing references and
        # saving generated images through the native Open and Save dialogs.
        values["com.apple.security.files.user-selected.read-write"] = True
        # flutter_secure_storage 9.x requires Keychain Sharing in both build
        # configurations. Preserve any access groups supplied by an overlay.
        values.setdefault("keychain-access-groups", [])
        with entitlements.open("wb") as destination:
            plistlib.dump(values, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("platforms", nargs="?", default=DEFAULT_PLATFORMS,
                        help=f"comma-separated list, default {DEFAULT_PLATFORMS}")
    parser.add_argument("--release-signing", action="store_true",
                        help="wire Android release builds to android/key.properties")
    args = parser.parse_args()

    platforms = [name.strip() for name in args.platforms.split(",") if name.strip()]
    unknown = [name for name in platforms if name not in DEFAULT_PLATFORM_LIST]
    if unknown:
        fail(f"unknown platform(s): {', '.join(unknown)}")
    if args.release_signing and "android" not in platforms:
        fail("--release-signing needs the android platform")

    with tempfile.TemporaryDirectory() as workdir:
        generated = generate(platforms, Path(workdir))
        for platform in platforms:
            source = generated / platform
            if not source.is_dir():
                fail(f"flutter create did not produce {platform}/")
            target = ROOT / platform
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(source, target)
            copied = copy_overlay(platform, target)
            print(f"+ {platform}: generated, {len(copied)} file(s) overlaid"
                  + (f" ({', '.join(copied)})" if copied else ""))
            if platform == "macos":
                patch_macos(target)
            if platform == "android":
                if not copied:
                    fail("platform/android/ contributed no files, so the media-save "
                         "channel and the launcher icons would be missing from the "
                         "APK; check that the overlay is still tracked by git")
                patch_android(target, args.release_signing)

    print("done. Next: flutter pub get && flutter run")


if __name__ == "__main__":
    main()
