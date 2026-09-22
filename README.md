# Tape Nexus

A native macOS app that watches your clipboard, queues any URL **yt-dlp supports**, and downloads it through `yt-dlp` — with a sleek dashboard UI, full per-item control, settings, and automatic yt-dlp updates on launch. A **Windows port** (Python + PySide6) is built alongside it from the same releases.

> Personal-use build: ad-hoc signed, **not notarized** (no paid Developer ID). Install + clear quarantine once and you're set.

## Download & install

### macOS
1. Download **`TapeNexus-1.0.5.pkg`** from the [latest release](https://github.com/jinthoa/TapeNexus/releases/latest).
2. Install it:
   ```bash
   sudo installer -pkg ~/Downloads/TapeNexus-1.0.5.pkg -target /
   ```
3. Clear the Gatekeeper quarantine flag (one time — it's ad-hoc signed, not notarized):
   ```bash
   xattr -dr com.apple.quarantine /Applications/TapeNexus.app
   ```
4. Launch from `/Applications` (right-click → **Open** the first time).

### Windows
1. Download **`TapeNexus-<ver>-win64.exe`** from the [latest release](https://github.com/jinthoa/TapeNexus/releases/latest) — a single portable executable.
2. Run it. `yt-dlp.exe` + `ffmpeg.exe` are bundled inside — no separate install.
3. SmartScreen may warn on first launch (unsigned) → **More info → Run anyway**. The first launch takes a few seconds (PyInstaller extracts its payload to a temp folder before the window opens).

The Windows `.exe` is built by GitHub Actions (`.github/workflows/build-windows.yml`) on `windows-latest` whenever a `v*` tag is pushed, so it's produced at zero cost with no Windows machine. See [`windows/README.md`](windows/README.md) to run from source or build it yourself.

## Features

- **Clipboard auto-grab** — detects copied http(s) URLs; only adds links yt-dlp actually supports (verified via `--simulate`). Unsupported links are silently skipped.
- **Sleek single-window dashboard** (dark UI) — thumbnails, title, host, format, live progress bar, speed, ETA, byte counts.
- **Unified list with filter** — All / Active / Done / Failed stay in one list; counts update live. "Clear done" removes finished items from the list. **Retry all** re-queues every failed/stopped item in one click.
- **Format preview** — on a queued item, "Show available formats…" runs yt-dlp `--list-formats` and shows every resolution / bitrate / size the link offers, so the per-item format picker is informed, not guessed. Picking a row applies it as a custom `-f`.
- **Per-item scheduling** — schedule a queued item to start at a later time (in addition to global quiet hours). The item waits in the queue until its start time, then kicks off automatically; the scheduler re-checks every minute.
- **Per-item controls** — pause · resume · stop · retry · reveal in Finder · remove · delete downloaded file. Per-row **format picker** and **clip** (time-range) editor on queued items.
- **Toolbar** — Clear done (finished items), Pause all, Retry all, paste-a-URL field. Paste a whole block of URLs (or drop a `.txt` file / drag links onto the window) to queue them all at once.
- **Cookies / auth** — pull cookies from Safari, Chrome, Firefox, Edge, Brave, or Chromium so age-restricted, members-only, and login-gated content downloads.
- **Playlist expansion** — optionally expand a playlist link into one queue item per video (capped).
- **Per-host organization** — optionally file downloads into `<site>/<title>.<ext>` (e.g. `YouTube/…`) instead of a flat folder.
- **Subtitle language picker** — choose which subtitle languages to embed.
- **Completion notifications + Dock badge** — native macOS notification when a download finishes or fails; Dock badge shows the active count.
- **Menu-bar mode** — run Tape Nexus as a status-bar-only app (no Dock icon); close the window to background it, use the status icon to bring it back.
- **Quiet hours** — automatically pause all downloads during a time window and resume when it ends. Per-item scheduling (above) layers on top for individual items.
- **Settings sheet** (`⌘,`) — destination folder, default format (Best / 1080p / 720p / Audio m4a / **Audio MP3** / Custom `-f`), concurrent downloads (1–4), clipboard poll interval, SponsorBlock, embed metadata, embed subtitles, plus all of the above.
- **Auto-start on detection** — optional (default **off**). When off, detected URLs queue up and wait for you to hit ▶ Start now; nothing starts on its own.
- **yt-dlp auto-update on launch** — fetches the latest macOS binary from GitHub and atomically swaps it. Can be disabled; manual "Check now" in Settings.
- **Persistence** — queue + history survive restarts (stored in `~/Library/Application Support/TapeNexus/`). Resolved metadata is cached, so re-copied links don't re-hit the network with `--simulate`.
- **App self-update** — checks GitHub for a newer Tape Nexus release; from Settings you can download the new `.pkg` and open Installer to update the app itself (launch checks are notify-only).
- **Universal build** — runs natively on Apple Silicon **and** Intel (arm64 + x86_64 app binary, plus universal `ffmpeg`/`ffprobe`).
- **PKG installer** — `build.sh` produces a `.pkg` that installs into `/Applications`; universal `ffmpeg` + `ffprobe` are bundled.

## Build & package

```bash
./build.sh
```

Produces:
- `build/TapeNexus.app`
- `build/TapeNexus-<version>.pkg`

Requirements: Xcode command-line tools (`swiftc`, `xcodebuild`, `pkgbuild`, `productbuild`, `codesign`) and `curl`. The script downloads the universal `yt-dlp_macos` binary and builds universal `ffmpeg`/`ffprobe` (arm64 slice from martin-riedl.de + x86_64 slice from evermeet.cx, merged with `lipo`) automatically.

To install a pkg you built yourself: `sudo installer -pkg build/TapeNexus-<version>.pkg -target /`, then `xattr -dr com.apple.quarantine /Applications/TapeNexus.app`.

## How it works

| Component | Job |
|---|---|
| `ClipboardMonitor` | Polls `NSPasteboard` every ~1.2s; extracts URLs; fast host pre-filter. |
| `SupportedURLs` | Curated yt-dlp host list (YouTube, Vimeo, Twitch, X, TikTok, SoundCloud, …) for the cheap pre-filter. |
| `YTDLPController` | Resolves the binary, runs `--simulate` to verify + fetch metadata, spawns downloads, parses JSON progress (`--progress-template`), sends process-tree signals for pause/resume/stop. |
| `DownloadManager` | Enforces concurrency; implements pause (SIGSTOP tree) / resume (SIGCONT) / stop (SIGTERM→SIGKILL) / retry / clear / delete. |
| `Updater` | Checks GitHub releases, downloads `yt-dlp_macos`, atomically swaps the Application Support copy. |
| `AppUpdater` | Checks GitHub for a newer Tape Nexus `.pkg`; downloads + opens Installer for the app itself (launch check is notify-only). |
| `Notifier` | Posts macOS user notifications on download completion/failure. |
| `MenuBarController` | Owns the menu-bar status item for menu-bar mode. |
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
  Updater.swift             yt-dlp GitHub release auto-update
  AppUpdater.swift          app GitHub release self-update (.pkg → Installer)
  Notifier.swift            macOS user notifications
  MenuBarController.swift   menu-bar status item
  SettingsStore.swift       JSON persistence
  Views/                    ContentView, QueueView, SettingsView, Theme
  Resources/Info.plist
  Resources/bin/yt-dlp      (universal, downloaded by build.sh)
  Resources/bin/ffmpeg      (universal, lipo'd by build.sh)
  Resources/bin/ffprobe     (universal, lipo'd by build.sh)
build.sh                    compile (arm64 + x86_64) → lipo → bundle → sign → .pkg
```

## Notes / limitations (v1)

- Not notarized → requires the one-time `xattr` quarantine clear (no paid Developer ID).