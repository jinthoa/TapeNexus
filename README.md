# Tape Nexus

A native macOS app that watches your clipboard, queues any URL **yt-dlp supports**, and downloads it through `yt-dlp` — with a sleek dashboard UI, full per-item control, settings, and automatic yt-dlp updates on launch.

> Personal-use build: ad-hoc signed, **not notarized** (no paid Developer ID). Install + clear quarantine once and you're set.

## Download & install

1. Download **`TapeNexus-1.0.0.pkg`** from the [latest release](https://github.com/jinthoa/TapeNexus/releases/latest).
2. Install it:
   ```bash
   sudo installer -pkg ~/Downloads/TapeNexus-1.0.0.pkg -target /
   ```
3. Clear the Gatekeeper quarantine flag (one time — it's ad-hoc signed, not notarized):
   ```bash
   xattr -dr com.apple.quarantine /Applications/TapeNexus.app
   ```
4. Launch from `/Applications` (right-click → **Open** the first time).

## Features

- **Clipboard auto-grab** — detects copied http(s) URLs; only adds links yt-dlp actually supports (verified via `--simulate`). Unsupported links are silently skipped.
- **Sleek single-window dashboard** (dark UI) — thumbnails, title, host, format, live progress bar, speed, ETA, byte counts.
- **Unified list with filter** — All / Active / Done / Failed stay in one list (no separate history page); counts update live.
- **Per-item controls** — pause · resume · stop · retry · reveal in Finder · remove · delete downloaded file.
- **Toolbar** — Clear done (finished items), Pause all, paste-a-URL field.
- **Settings sheet** (`⌘,`) — destination folder, default format (Best / 1080p / 720p / Audio / Custom `-f`), concurrent downloads (1–4), clipboard poll interval, SponsorBlock, embed metadata, embed subtitles.
- **Auto-start on detection** — optional (default **off**). When off, detected URLs queue up and wait for you to hit ▶ Start now.
- **yt-dlp auto-update on launch** — fetches the latest macOS binary from GitHub and atomically swaps it. Can be disabled; manual "Check now" in Settings.
- **Persistence** — queue + history survive restarts (stored in `~/Library/Application Support/TapeNexus/`).
- **PKG installer** — `build.sh` produces a `.pkg` that installs into `/Applications`; signed/notarized arm64 `ffmpeg` + `ffprobe` are bundled.

## Build & package

```bash
./build.sh
```

Produces:
- `build/TapeNexus.app`
- `build/TapeNexus-<version>.pkg`

Requirements: Xcode command-line tools (`swiftc`, `xcodebuild`, `pkgbuild`, `productbuild`, `codesign`) and `curl`. The script downloads the `yt-dlp_macos` binary and arm64 `ffmpeg`/`ffprobe` automatically.

To install a pkg you built yourself: `sudo installer -pkg build/TapeNexus-<version>.pkg -target /`, then `xattr -dr com.apple.quarantine /Applications/TapeNexus.app`.

## How it works

| Component | Job |
|---|---|
| `ClipboardMonitor` | Polls `NSPasteboard` every ~1.2s; extracts URLs; fast host pre-filter. |
| `SupportedURLs` | Curated yt-dlp host list (YouTube, Vimeo, Twitch, X, TikTok, SoundCloud, …) for the cheap pre-filter. |
| `YTDLPController` | Resolves the binary, runs `--simulate` to verify + fetch metadata, spawns downloads, parses JSON progress (`--progress-template`), sends process-tree signals for pause/resume/stop. |
| `DownloadManager` | Enforces concurrency; implements pause (SIGSTOP tree) / resume (SIGCONT) / stop (SIGTERM→SIGKILL) / retry / clear / delete. |
| `Updater` | Checks GitHub releases, downloads `yt-dlp_macos`, atomically swaps the Application Support copy. |
| `SettingsStore` | JSON persistence under Application Support. |

Pause/resume use real POSIX process signals (`SIGSTOP`/`SIGCONT`) on the yt-dlp process tree, so they genuinely halt and resume I/O.

## Project layout

```
Sources/TapeNexus/
  App.swift                 AppKit bootstrap + window + main menu (@main)
  AppState.swift            central @MainActor ObservableObject model
  Models.swift              DownloadItem, AppSettings, statuses
  SupportedURLs.swift       clipboard URL pre-filter
  ClipboardMonitor.swift    pasteboard polling
  YTDLP.swift               yt-dlp wrapper (version/simulate/download/signals)
  DownloadManager.swift     lifecycle + concurrency + controls
  Updater.swift             GitHub release auto-update
  SettingsStore.swift       JSON persistence
  Views/                    ContentView, QueueView, SettingsView, Theme
  Resources/Info.plist
  Resources/bin/yt-dlp      (downloaded by build.sh)
  Resources/bin/ffmpeg      (arm64, downloaded by build.sh)
  Resources/bin/ffprobe     (arm64, downloaded by build.sh)
build.sh                    compile → bundle → sign → .pkg
```

## Notes / limitations (v1)

- arm64 only (built on Apple Silicon). For Intel, add a universal build target.
- Not notarized → requires the one-time `xattr` quarantine clear.
- `--simulate` makes a network call per detected URL; the host pre-filter and poll cadence keep this cheap.
- The app itself doesn't self-update (Sparkle etc.); only the bundled `yt-dlp` auto-updates. Rebuild + reinstall to update the app.