#!/bin/sh
# Downloads the pinned PDFium build (https://github.com/bblanchon/pdfium-binaries, MIT/BSD)
# into Vendor/pdfium. Run once before building.
set -eu
VERSION="chromium/8125"
SHA256="0cf06803b9a4acc489fc967a1b05990622ca1cf41fa027ff9cc89eeab9b19279"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/pdfium"

[ -f "$DEST/lib/libpdfium.dylib" ] && { echo "PDFium already present in $DEST"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/pdfium.tgz" "https://github.com/bblanchon/pdfium-binaries/releases/download/$VERSION/pdfium-mac-univ.tgz"
echo "$SHA256  $TMP/pdfium.tgz" | shasum -a 256 -c -
mkdir -p "$DEST"
tar -xzf "$TMP/pdfium.tgz" -C "$DEST"
# The prebuilt library's install name is ./libpdfium.dylib; apps load embedded libraries via @rpath.
install_name_tool -id @rpath/libpdfium.dylib "$DEST/lib/libpdfium.dylib"
codesign --force --sign - "$DEST/lib/libpdfium.dylib"
echo "PDFium $VERSION installed in $DEST"
