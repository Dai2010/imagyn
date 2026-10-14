#!/usr/bin/env bash
# Build the Linux packages (.deb and .rpm) from a finished Flutter bundle.
#
#   scripts/package_linux.sh <bundle-dir> <version> <output-dir>
#
# <bundle-dir>  what `flutter build linux --release` produced, e.g.
#               build/linux/x64/release/bundle
# <version>     the package version, e.g. 0.1.0 (the pubspec version, no build
#               number)
# <output-dir>  where the .deb and the .rpm land
#
# Requires dpkg-deb and rpmbuild; the build workflow installs both. The Arch
# package is built separately — makepkg only runs on Arch, see
# scripts/package_arch.sh. Icons come from platform/icons/, so run
# scripts/make_icons.sh first if they are missing.
set -euo pipefail

BUNDLE=${1:?usage: package_linux.sh <bundle-dir> <version> <output-dir>}
VERSION=${2:?usage: package_linux.sh <bundle-dir> <version> <output-dir>}
OUT=${3:?usage: package_linux.sh <bundle-dir> <version> <output-dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

PKG=imagyn
MAINTAINER="Dai2010 <Dai2010@users.noreply.github.com>"
HOMEPAGE=https://github.com/Dai2010/imagyn
SUMMARY="Minimalist AI image studio"
# Debian wants the continuation lines of Description pre-wrapped and indented;
# RPM takes the same text as a plain paragraph.
DEB_DESCRIPTION='Imagyn generates and edits images through any OpenAI- or Anthropic-compatible
 endpoint you configure. The Gallery and the Agent share one local artwork
 library: API keys stay in the system keyring and images never leave your
 device except to the service you pointed the app at.'
RPM_DESCRIPTION='Imagyn generates and edits images through any OpenAI- or Anthropic-compatible
endpoint you configure. The Gallery and the Agent share one local artwork
library: API keys stay in the system keyring and images never leave your device
except to the service you pointed the app at.'

[ -x "$BUNDLE/$PKG" ] || { echo "package_linux: no $PKG binary in $BUNDLE" >&2; exit 1; }
[ -f "$ROOT/packaging/linux/$PKG.desktop" ] || { echo "package_linux: the .desktop file is missing" >&2; exit 1; }
[ -f "$ROOT/LICENSE" ] || { echo "package_linux: LICENSE is missing" >&2; exit 1; }
for size in 16 32 48 64 128 256 512; do
  [ -f "$ROOT/platform/icons/png/$size.png" ] ||
    { echo "package_linux: platform/icons/png/$size.png is missing; run scripts/make_icons.sh" >&2; exit 1; }
done

mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# --- the installed layout, shared by both packages ----------------------------
install -d "$STAGE/usr/bin" "$STAGE/usr/lib/$PKG" "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/licenses/$PKG"
cp -R "$BUNDLE/." "$STAGE/usr/lib/$PKG/"
chmod 755 "$STAGE/usr/lib/$PKG/$PKG"
# The bundle locates its own lib/ through /proc/self/exe, which follows this
# symlink to the real file, so a symlink into /usr/bin is enough.
ln -s "/usr/lib/$PKG/$PKG" "$STAGE/usr/bin/$PKG"
install -m 644 "$ROOT/packaging/linux/$PKG.desktop" "$STAGE/usr/share/applications/$PKG.desktop"
install -m 644 "$ROOT/LICENSE" "$STAGE/usr/share/licenses/$PKG/LICENSE"
for size in 16 32 48 64 128 256 512; do
  install -d "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps"
  install -m 644 "$ROOT/platform/icons/png/$size.png" \
    "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/$PKG.png"
done

# --- .deb ---------------------------------------------------------------------
DEBIAN="$STAGE/DEBIAN"
install -d "$DEBIAN"
# libsecret and jsoncpp are what flutter_secure_storage's Linux plugin links
# against, so they belong in Depends even though nothing here names them. The
# "|" alternatives cover the t64 rename in Ubuntu 24.04. dpkg-shlibdeps would
# derive this from the bundle exactly; these are the known set.
cat > "$DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: graphics
Priority: optional
Architecture: amd64
Installed-Size: $(du -sk "$STAGE/usr" | cut -f1)
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libblkid1, liblzma5, libstdc++6, libsecret-1-0, libjsoncpp25
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Description: $SUMMARY
$DEB_DESCRIPTION
CONTROL

# Only refresh the caches; a missing tool must not fail the installation.
cat > "$DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
POSTINST
chmod 755 "$DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$STAGE" "$OUT/${PKG}_${VERSION}_amd64.deb"
echo "package_linux: $(basename "$OUT/${PKG}_${VERSION}_amd64.deb")"
rm -rf "$DEBIAN"

# --- .rpm ---------------------------------------------------------------------
# rpmbuild fills in the shared-library requirements itself from the ELF headers,
# so only the toolkit has to be named by hand.
SPEC=$(mktemp -d)
cat > "$SPEC/$PKG.spec" <<SPECFILE
Name:           $PKG
Version:        $VERSION
Release:        1
Summary:        $SUMMARY
License:        GPL-3.0-or-later
URL:            $HOMEPAGE
BuildArch:      x86_64

Requires:       gtk3
Requires:       glib2

%description
$RPM_DESCRIPTION

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a %{_stage}/. %{buildroot}/
chmod 755 %{buildroot}/usr/lib/$PKG/$PKG

%files
/usr/bin/$PKG
/usr/lib/$PKG
/usr/share/applications/$PKG.desktop
/usr/share/icons/hicolor/16x16/apps/$PKG.png
/usr/share/icons/hicolor/32x32/apps/$PKG.png
/usr/share/icons/hicolor/48x48/apps/$PKG.png
/usr/share/icons/hicolor/64x64/apps/$PKG.png
/usr/share/icons/hicolor/128x128/apps/$PKG.png
/usr/share/icons/hicolor/256x256/apps/$PKG.png
/usr/share/icons/hicolor/512x512/apps/$PKG.png
%license /usr/share/licenses/$PKG/LICENSE
SPECFILE

# No %prep and no %build: the input is an already-built Flutter bundle.
rpmbuild -bb --define "_stage $STAGE" --define "_rpmdir $SPEC/rpms" \
  --define "_topdir $SPEC" "$SPEC/$PKG.spec" >/dev/null
find "$SPEC/rpms" -name '*.rpm' -exec mv {} "$OUT/" \;
echo "package_linux: $(ls "$OUT"/*.rpm | xargs -n1 basename)"

# --- Arch Linux package -------------------------------------------------------
# makepkg only runs on Arch and refuses to run as root, so the archive is
# written here instead: a .pkg.tar.zst is a zstd-compressed tar holding .PKGINFO
# plus the file tree, and `pacman -U` accepts exactly that. The .MTREE index is
# left out — it is only consulted when verifying a synced repository. The file
# layout is the same one the .deb and .rpm carry.
BSDTAR=${BSDTAR:-bsdtar}
command -v "$BSDTAR" >/dev/null ||
  { echo "package_linux: bsdtar is required (package libarchive-tools)" >&2; exit 1; }
ARCHIVE="$OUT/${PKG}-${VERSION}-1-x86_64.pkg.tar.zst"
# libsecret and jsoncpp come from flutter_secure_storage, sqlite from
# sqflite_common_ffi; pacman has to pull them in, so they are named here.
# (.PKGINFO has no comment syntax, hence this note living outside the heredoc.)
cat > "$STAGE/.PKGINFO" <<PKGINFO
pkgname = $PKG
pkgbase = $PKG
pkgver = $VERSION-1
pkgdesc = $SUMMARY
url = $HOMEPAGE
builddate = $(date +%s)
packager = $MAINTAINER
size = $(du -sb "$STAGE/usr" | cut -f1)
arch = x86_64
license = GPL-3.0-or-later
depend = gtk3
depend = glib2
depend = libsecret
depend = jsoncpp
depend = sqlite
PKGINFO
# Archived as root:0 rather than as whoever ran the build, or pacman would
# unpack /usr/bin/imagyn owned by the runner's own account.
"$BSDTAR" --zstd --uid 0 --gid 0 --uname root --gname root \
  -cf "$ARCHIVE" -C "$STAGE" .PKGINFO usr
echo "package_linux: $(basename "$ARCHIVE")"
