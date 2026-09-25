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

# ── 1b. Fetch ffmpeg + ffprobe (universal: arm64 + x86_64) ───────────────────
# yt-dlp needs ffmpeg to merge bestvideo+bestaudio into one file. We bundle a
# UNIVERSAL ffmpeg/ffprobe so the app runs on both Apple Silicon and Intel:
# arm64 slice from martin-riedl.de (signed/notarized, native on Apple Silicon
# — no Rosetta, no "Intel app support ending" warning) + x86_64 slice from
# evermeet.cx (native on Intel). lipo merges them into one fat binary. Cached
# in Resources/bin like yt-dlp.
FFMPEG="$RES/bin/ffmpeg"
FFPROBE="$RES/bin/ffprobe"
MR_ARM="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
EV_X86="https://evermeet.cx/ffmpeg/getrelease"
is_universal() {
  local a; a=$(lipo -archs "$1" 2>/dev/null)
  [[ "$a" == *"arm64"* && "$a" == *"x86_64"* ]]
}
if ! is_universal "$FFMPEG" || ! is_universal "$FFPROBE"; then
  echo "▶ Fetching ffmpeg + ffprobe (arm64 martin-riedl.de + x86_64 evermeet.cx)…"
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/arm64" "$tmp/x86"
  curl -fsSL -o "$tmp/arm64-ffmpeg.zip"  "$MR_ARM/ffmpeg.zip"
  curl -fsSL -o "$tmp/arm64-ffprobe.zip" "$MR_ARM/ffprobe.zip"
  curl -fsSL -o "$tmp/x86-ffmpeg.zip"    "$EV_X86/zip"
  curl -fsSL -o "$tmp/x86-ffprobe.zip"   "$EV_X86/ffprobe/zip"
  ( cd "$tmp/arm64" && unzip -o ../arm64-ffmpeg.zip >/dev/null  && unzip -o ../arm64-ffprobe.zip >/dev/null )
  ( cd "$tmp/x86"   && unzip -o ../x86-ffmpeg.zip >/dev/null    && unzip -o ../x86-ffprobe.zip >/dev/null )
  lipo -create "$tmp/arm64/ffmpeg"  "$tmp/x86/ffmpeg"  -output "$FFMPEG"
  lipo -create "$tmp/arm64/ffprobe" "$tmp/x86/ffprobe" -output "$FFPROBE"
  chmod +x "$FFMPEG" "$FFPROBE"
  rm -rf "$tmp"
fi
echo "  ffmpeg bundled: $("$FFMPEG" -version 2>/dev/null | head -1) [$(lipo -archs "$FFMPEG")]"

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

# Universal binary: compile each arch separately (swiftc has no `universal`
# target), then lipo them together. Runs natively on Apple Silicon and Intel.
echo "▶ Compiling (arm64)…"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework Combine \
  -framework UserNotifications -framework Network -framework AuthenticationServices -framework Security \
  "${SWIFT_FILES[@]}" -o "$BUILD/TapeNexus.arm64"
echo "▶ Compiling (x86_64)…"
swiftc -O -swift-version 5 -target x86_64-apple-macos14 -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework Combine \
  -framework UserNotifications -framework Network -framework AuthenticationServices -framework Security \
  "${SWIFT_FILES[@]}" -o "$BUILD/TapeNexus.x86_64"
echo "▶ Linking universal binary…"
lipo -create "$BUILD/TapeNexus.arm64" "$BUILD/TapeNexus.x86_64" -output "$APP/Contents/MacOS/TapeNexus"
rm -f "$BUILD/TapeNexus.arm64" "$BUILD/TapeNexus.x86_64"

# ── 3. Assemble the bundle ───────────────────────────────────────────────────
echo "▶ Assembling .app bundle…"
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
# Cloud-sync config (Supabase URL + publishable/anon key). The committed
# sync.json is an empty template (sync disabled); if a gitignored
# sync.local.json exists with real credentials, bake that in instead so the
# key ships in the app but never enters the repo.
if [[ -f "$RES/sync.local.json" ]]; then
  cp "$RES/sync.local.json" "$APP/Contents/Resources/sync.json"
else
  cp "$RES/sync.json" "$APP/Contents/Resources/sync.json"
fi
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

# ── 4. Code sign ─────────────────────────────────────────────────────────────
# Resolve Developer ID identities from the keychain. If the Developer ID
# Application cert is present, sign for distribution (hardened runtime +
# entitlements — required for notarization); otherwise fall back to an ad-hoc
# sign so local/CI machines without the cert still produce a runnable app.
APP_IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application:' | sed 's/.*"\(.*\)".*/\1/' || true)"
INST_IDENTITY="$(security find-identity -v | grep -m1 'Developer ID Installer:' | sed 's/.*"\(.*\)".*/\1/' || true)"
ENT="$RES/TapeNexus.entitlements"
HELPER_ENT="$RES/TapeNexus.helper-entitlements"

if [[ -n "$APP_IDENTITY" ]]; then
  echo "▶ Code signing (Developer ID Application)…"
  # Sign the bundled Mach-O helpers first (innermost-out). They are standalone
  # third-party/frozen binaries, so they get hardened runtime + the permissive
  # helper entitlements (unsigned-exec memory + disabled library validation).
  for bin in yt-dlp ffmpeg ffprobe; do
    codesign --force --options runtime --sign "$APP_IDENTITY" \
      --entitlements "$HELPER_ENT" "$APP/Contents/Resources/bin/$bin"
  done
  # Sign the app bundle itself (no --deep: helpers are already signed above).
  codesign --force --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$ENT" "$APP"
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
else
  echo "▶ Code signing (ad-hoc — no Developer ID Application cert in keychain)…"
  APP_IDENTITY="-"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign warning ignored)"
fi

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

# Installer scripts: quit a running TapeNexus before replacing the bundle,
# then relaunch the new copy in the console user's session once installed.
# (postinstall runs as root; a bare `open` would launch the app under root
# and break its GUI/sandbox, so resolve the logged-in user and use launchctl.)
SCRIPTS="$BUILD/scripts"
rm -rf "$SCRIPTS"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/preinstall" <<'SH'
#!/bin/bash
# Quit any running TapeNexus so the installer can overwrite the bundle — but
# ONLY for a manual install (double-click the .pkg / `sudo installer`). An
# in-app self-update (Settings → Update) writes /tmp/tn-self-update holding
# the orchestrating app's PID before invoking us; that app is blocked on the
# installer's exit and quits + relaunches itself once we return, so killing
# it here would abort the install ("update failed"). Skip the kill when the
# sentinel names a live TapeNexus. Always exit 0 so a fresh install (app not
# running / no sentinel) never fails the installer.
SENTINEL="/tmp/tn-self-update"
in_app=0
if [ -r "$SENTINEL" ]; then
  spid=$(tr -dc '0-9' < "$SENTINEL" 2>/dev/null)
  if [ -n "$spid" ]; then
    case "$(ps -o comm= -p "$spid" 2>/dev/null)" in
      *TapeNexus*) in_app=1;;
    esac
  fi
fi
if [ "$in_app" = "0" ]; then
  killall -TERM "TapeNexus" 2>/dev/null
  sleep 1
  killall -KILL "TapeNexus" 2>/dev/null
fi
exit 0
SH
cat > "$SCRIPTS/postinstall" <<'SH'
#!/bin/bash
# Clear the in-app self-update sentinel (set by the app's updater), then
# relaunch the freshly installed TapeNexus in the logged-in user's session.
# postinstall runs as root, so resolve the console user and re-exec `open`
# under their uid via launchctl (a root `open` spawns the app under root,
# which breaks the GUI and per-user support-dir resolution). For an in-app
# update the old app is still running and quitting itself, so `open` just
# activates it — the app's own relaunch does the restart; for a manual
# install this IS the restart.
rm -f /tmp/tn-self-update 2>/dev/null
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  launchctl asuser "$(id -u "$CONSOLE_USER")" open /Applications/TapeNexus.app
fi
exit 0
SH
chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"
find "$SCRIPTS" -name '._*' -delete 2>/dev/null || true

COMPONENT_PKG="$BUILD/TapeNexus.component.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --install-location / \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts "$SCRIPTS" \
  "$COMPONENT_PKG"

# pkgbuild archives the Scripts dir with an xattr-preserving cpio that emits
# AppleDouble `._preinstall`/`._postinstall` sidecars (modern macOS stamps
# every file with a non-removable com.apple.provenance xattr that cpio keeps
# as `._` companions). Those stray non-executable entries in the Scripts
# archive make the GUI Installer.app fail right after authentication on some
# macOS versions (the CLI `installer` tolerates them). Plain `cpio` does NOT
# emit them, so re-create the Scripts archive cleanly and re-pack the xar.
COMP_XAR="$BUILD/comp_xar"
rm -rf "$COMP_XAR"
mkdir -p "$COMP_XAR"
( cd "$COMP_XAR" && xar -x -f "$COMPONENT_PKG" )
if [[ -f "$COMP_XAR/Scripts" ]]; then
  ( cd "$SCRIPTS" && find . -print0 | cpio -o -0 -H newc 2>/dev/null | gzip > "$COMP_XAR/Scripts" )
  rm -f "$COMPONENT_PKG"
  ( cd "$COMP_XAR" && xar -c -f "$COMPONENT_PKG" . )
fi
rm -rf "$COMP_XAR"

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

PKG="$BUILD/TapeNexus-$VERSION.pkg"
if [[ -n "$INST_IDENTITY" ]]; then
  echo "  signing .pkg with Developer ID Installer…"
  productbuild --distribution "$DIST" --package-path "$BUILD" --sign "$INST_IDENTITY" "$PKG"
else
  productbuild --distribution "$DIST" --package-path "$BUILD" "$PKG"
fi

rm -rf "$PAYLOAD"
rm -f "$COMPONENT_PKG"

# ── 6. Notarize + staple (opt-in via --notarize) ─────────────────────────────
# Notarization submits the signed .pkg to Apple, waits for approval, then
# staples the notarization ticket so Gatekeeper accepts it with no quarantine
# dance. Gated behind --notarize so plain `./build.sh` stays a fast signed build
# for local testing. Auth credentials live in ~/.tapenexus/notary.env (never in
# the repo); build.sh supports EITHER an App Store Connect API key (TN_KEY,
# TN_KEY_ID, TN_ISSUER) OR an Apple ID + app-specific password (TN_APPLE_ID,
# TN_APP_PASSWORD). Team ID is required for both.
NOTARIZE=0
for arg in "$@"; do [[ "$arg" == "--notarize" ]] && NOTARIZE=1; done

NOTARIZED=0
if [[ "$NOTARIZE" -eq 1 ]]; then
  NOTARY_ENV="$HOME/.tapenexus/notary.env"
  if [[ ! -f "$NOTARY_ENV" ]]; then
    echo "✖ --notarize given but $NOTARY_ENV not found." >&2
    echo "  Put TN_APPLE_ID / TN_APP_PASSWORD / TN_TEAM_ID (or TN_KEY / TN_KEY_ID / TN_ISSUER / TN_TEAM_ID) in it." >&2
    exit 1
  fi
  set -a; . "$NOTARY_ENV"; set +a
  if [[ -z "${TN_TEAM_ID:-}" ]]; then
    echo "✖ TN_TEAM_ID missing in $NOTARY_ENV." >&2; exit 1
  fi
  # Store (or refresh) notarytool credentials in the keychain under a profile.
  echo "▶ Storing notarytool credentials in keychain…"
  if [[ -n "${TN_KEY:-}" && -n "${TN_KEY_ID:-}" && -n "${TN_ISSUER:-}" ]]; then
    # App Store Connect API key flow. --team-id must NOT be passed here: it
    # belongs to the app-specific-password flow, and mixing it with --key makes
    # notarytool refuse with "cannot store both credential types". The team is
    # implied by the API key + issuer.
    xcrun notarytool store-credentials "TN-NOTARY" \
      --key "$TN_KEY" --key-id "$TN_KEY_ID" --issuer "$TN_ISSUER"
  elif [[ -n "${TN_APPLE_ID:-}" && -n "${TN_APP_PASSWORD:-}" ]]; then
    xcrun notarytool store-credentials "TN-NOTARY" \
      --apple-id "$TN_APPLE_ID" --team-id "$TN_TEAM_ID" --password "$TN_APP_PASSWORD"
  else
    echo "✖ $NOTARY_ENV has neither an API key nor an Apple ID + app password." >&2
    exit 1
  fi
  echo "▶ Submitting $PKG to Apple notarization (waits for approval, usually 2–10 min)…"
  xcrun notarytool submit "$PKG" --keychain-profile "TN-NOTARY" --wait
  echo "▶ Stapling notarization ticket…"
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
  echo "▶ Gatekeeper check…"
  spctl -a -t install "$PKG" && echo "  Gatekeeper: accepted" || echo "  (spctl check could not confirm — inspect with `spctl -a -t install -v \"$PKG\"`)"
  NOTARIZED=1
fi

echo
echo "✔ Done."
echo "  App:  $APP"
echo "  Pkg:  $PKG"
echo
echo "  Run dev:  \"$APP/Contents/MacOS/TapeNexus\""
echo
if [[ "$NOTARIZED" -eq 1 ]]; then
  echo "  Signed with Developer ID + notarized + stapled. Gatekeeper accepts it outright."
elif [[ "$APP_IDENTITY" != "-" ]]; then
  echo "  Signed with Developer ID (not notarized). Pass --notarize to submit to Apple."
else
  echo "  Note: unsigned/ad-hoc. To open after install, right-click → Open, or:"
  echo "    xattr -dr com.apple.quarantine /Applications/TapeNexus.app"
fi