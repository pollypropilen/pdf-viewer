#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"

# Prefer the Xcode toolchain when Command Line Tools is selected globally.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/private/tmp}/pdf-viewer-clang-cache"
export MACOSX_DEPLOYMENT_TARGET=13.0

vendor="$PWD/.build/djvulibre"
archive="$PWD/Vendor/djvulibre-3.5.30.tar.gz"
expected_sha="ee5e457d4cfebe566f94b99e5e3d3cc7f5c79ddb741c2ac2ba2e456f00329644"
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "DjVuLibre source checksum mismatch" >&2
  exit 1
fi
if [[ ! -f "$vendor/install/lib/libdjvulibre.a" ]]; then
  mkdir -p "$vendor"
  tar -xf "$archive" -C "$vendor"
  mkdir -p "$vendor/obj"
  (
    cd "$vendor/obj"
    ../djvulibre-3.5.30/configure --disable-shared --enable-static \
      --without-jpeg --without-tiff --disable-desktopfiles --disable-xmltools \
      --prefix="$vendor/install"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )
fi
xcrun clang -O2 -c -I "$vendor/install/include" \
  Sources/CDjVu/DjVuBridge.c -o "$vendor/DjVuBridge.o"

app="$PWD/dist/pdf-viewer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos13.0" \
  -import-objc-header Sources/CDjVu/DjVuBridge.h \
  -framework AppKit -framework PDFKit \
  Sources/PDFViewer/main.swift Sources/PDFViewer/ViewerWindowController.swift \
  Sources/PDFViewer/DjVuDocument.swift "$vendor/DjVuBridge.o" \
  "$vendor/install/lib/libdjvulibre.a" -lc++ -lz -liconv \
  -o "$app/Contents/MacOS/PDFViewer"
cp Resources/pdf-viewer.png "$app/Contents/Resources/pdf-viewer.png"
cp Resources/pdf-viewer.icns "$app/Contents/Resources/pdf-viewer.icns"
cp Resources/chrome-grain.png "$app/Contents/Resources/chrome-grain.png"
cp "$vendor/djvulibre-3.5.30/COPYING" "$app/Contents/Resources/DjVuLibre-COPYING"
cp LICENSE "$app/Contents/Resources/PDFViewer-COPYING"
cp Info.plist "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/PDFViewer"
codesign --force --deep --sign - "$app"
echo "$app"
