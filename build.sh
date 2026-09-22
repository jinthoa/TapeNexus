#!/usr/bin/env bash
set -euo pipefail

# Tape Nexus — build, bundle, sign, and package into a .pkg installer.
# Produces:
#   build/TapeNexus.app           (the app)
#   build/TapeNexus-<ver>.pkg      (the installer)

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources/TapeNexus"
RES="$SRC/Resources"
BUILD="$ROOT/build"
APP="$BUILD/TapeNexus.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RES/Info.plist")"
IDENTIFIER="com.bpenven.tapenexus"
SDK="$(xcrun --show-sdk-path)"

echo "▶ Tape Nexus build — version $VERSION"

# ── 1. Fetch yt-dlp macOS standalone binary (bundled fallback) ───────────────
YTDLP="$RES/bin/yt-dlp"
mkdir -p "$RES/bin"
if [[ ! -x "$YTDLP" ]]; then
  echo "▶ Downloading yt-dlp_macos…"
  curl -fsSL -o "$YTDLP" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
  chmod +x "$YTDLP"
fi
echo "  yt-dlp bundled: $("$YTDLP" --version 2>/dev/null | head -1)"

# ── 1b. Fetch ffmpeg + ffprobe (martin-riedl.de arm64 static builds) ────────
# yt-dlp needs ffmpeg to merge bestvideo+bestaudio into one file. We bundle
# native arm64 builds (signed + notarized) from martin-riedl.de so there's no
# Rosetta 2 dependency and no "Intel app support ending" warning. Cached in
# Resources/bin like yt-dlp. Stable redirect URLs always point at the newest
# release build.
FFMPEG="$RES/bin/ffmpeg"
FFPROBE="$RES/bin/ffprobe"
BASE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
if [[ ! -x "$FFMPEG" || ! -x "$FFPROBE" ]]; then
  echo "▶ Fetching ffmpeg + ffprobe (martin-riedl.de, arm64)…"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/ffmpeg.zip" "$BASE/ffmpeg.zip"
  curl -fsSL -o "$tmp/ffprobe.zip" "$BASE/ffprobe.zip"
  ( cd "$tmp" && unzip -o ffmpeg.zip >/dev/null && unzip -o ffprobe.zip >/dev/null )
  chmod +x "$tmp/ffmpeg" "$tmp/ffprobe"
  mv "$tmp/ffmpeg" "$FFMPEG"
  mv "$tmp/ffprobe" "$FFPROBE"
  rm -rf "$tmp"
fi
echo "  ffmpeg bundled: $("$FFMPEG" -version 2>/dev/null | head -1)"

# ── 2. Compile Swift sources ─────────────────────────────────────────────────
echo "▶ Compiling…"
# Start from a clean build dir. A past `sudo` action can leave root-owned files
# here that the current user can't delete — fail loudly with a fix instead of
# producing a half-cleaned bundle.
if [[ -e "$BUILD" ]] && ! rm -rf "$BUILD" 2>/dev/null; then
  echo "✖ Cannot clean $BUILD (some files are root-owned)." >&2
  echo "  Fix: sudo rm -rf \"$BUILD\"" >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

SWIFT_FILES=()
while IFS= read -r -d '' f; do
  SWIFT_FILES+=("$f")
done < <(find "$SRC" -name '*.swift' -print0)

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macos14 \
  -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework Combine \
  "${SWIFT_FILES[@]}" \
  -o "$APP/Contents/MacOS/TapeNexus"

# ── 3. Assemble the bundle ───────────────────────────────────────────────────
echo "▶ Assembling .app bundle…"
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
cp "$YTDLP" "$APP/Contents/Resources/bin/yt-dlp"
chmod +x "$APP/Contents/Resources/bin/yt-dlp"
# ffmpeg + ffprobe (for bestvideo+bestaudio merging)
cp "$FFMPEG" "$APP/Contents/Resources/bin/ffmpeg"
cp "$FFPROBE" "$APP/Contents/Resources/bin/ffprobe"
chmod +x "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"

# app icon (Info.plist references CFBundleIconFile=AppIcon → AppIcon.icns)
if [[ -f "$RES/AppIcon.icns" ]]; then
  cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  (warning: AppIcon.icns missing — app will have a generic icon)"
fi

# minimal PkgInfo
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── 4. Ad-hoc code sign (local use; not notarized) ───────────────────────────
echo "▶ Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign warning ignored)"

# Register the bundle with LaunchServices + re-index Spotlight so the app
# icon shows up in Spotlight/Finder search (LS caches per-path; force-refresh).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
echo "▶ Registering icon with LaunchServices / Spotlight…"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
mdimport "$APP" >/dev/null 2>&1 || true

# ── 5. Build the .pkg installer ──────────────────────────────────────────────
echo "▶ Building .pkg…"
PAYLOAD="$BUILD/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/Applications"
cp -R "$APP" "$PAYLOAD/Applications/"

COMPONENT_PKG="$BUILD/TapeNexus.component.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --install-location / \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  "$COMPONENT_PKG"

DIST="$BUILD/Distribution.xml"
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="2">
  <title>Tape Nexus $VERSION</title>
  <organization>$IDENTIFIER</organization>
  <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
  <domains enable_localSystem="true"/>
  <choices-outline>
    <line choice="default">
      <line choice="$IDENTIFIER"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$IDENTIFIER" visible="false">
    <pkg-ref id="$IDENTIFIER"/>
  </choice>
  <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">TapeNexus.component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution "$DIST" --package-path "$BUILD" "$BUILD/TapeNexus-$VERSION.pkg"

rm -rf "$PAYLOAD"
rm -f "$COMPONENT_PKG"

echo
echo "✔ Done."
echo "  App:  $APP"
echo "  Pkg:  $BUILD/TapeNexus-$VERSION.pkg"
echo
echo "  Run dev:  \"$APP/Contents/MacOS/TapeNexus\""
echo
echo "  Note: unsigned/ad-hoc. To open after install, right-click → Open, or:"
echo "    xattr -dr com.apple.quarantine /Applications/TapeNexus.app"