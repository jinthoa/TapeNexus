# YT Grabber — Design Spec

**Date:** 2026-09-21
**Platform:** macOS 14+ (arm64), native Swift / SwiftUI / AppKit
**Goal:** A macOS app (installed via `.pkg`) that watches the clipboard, adds only yt-dlp-supported URLs to a sleek download queue, and drives `yt-dlp` with full per-item control and yt-dlp auto-update on launch.

## Overview

A native macOS app with a full window dashboard (Variation B from mockups). It bundles a standalone `yt-dlp` binary, polls the system pasteboard for URLs, verifies each candidate with `yt-dlp --simulate` (only supported URLs are enqueued), and runs downloads as child processes with parsed progress. Settings and queue state persist across launches; `yt-dlp` is auto-updated from GitHub releases on startup.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  App (AppKit bootstrap + SwiftUI hosted in NSWindow)      │
│  ┌────────────┐   ┌───────────────────────────────────┐  │
│  │  Sidebar   │   │  Detail (Queue / History / Settings) │  │
│  │  nav       │   │  SwiftUI views (environmentObject)  │  │
│  └────────────┘   └───────────────────────────────────┘  │
│                         │ reads/mutates                   │
│                  ┌──────▼──────┐                          │
│                  │  AppState   │  ObservableObject        │
│                  │  @Published │  (main actor)            │
│                  └──────┬──────┘                          │
│         ┌───────────────┼───────────────┐                 │
│   ┌─────▼──────┐  ┌─────▼──────┐  ┌─────▼──────┐          │
│   │ Clipboard   │  │ Download   │  │ Settings   │          │
│   │ Monitor     │  │ Manager    │  │ Store      │          │
│   └─────┬──────┘  └─────┬──────┘  └─────┬──────┘          │
│         │ url           │ spawns        │ JSON            │
│         ▼                ▼               ▼                 │
│   SupportedURLs    YTDLPController    ~/Library/          │
│   (host prefilter) (Process + signals) Application        │
│                          │              Support/YTGrabber │
│                          ▼                               │
│                   yt-dlp binary (AS copy, auto-updated)    │
│                   + Updater (GitHub releases)              │
└──────────────────────────────────────────────────────────┘
```

## Components

### AppState (`AppState.swift`)
`ObservableObject` (main actor). `@Published` queue items, history, settings, sidebar selection, updater status. Owns `ClipboardMonitor`, `DownloadManager`, `SettingsStore`, `YTDLPController`, `Updater`. Provides the methods views call: `addManualURL`, `pause`, `resume`, `stop`, `retry`, `removeItem`, `deleteFile`, `clearFinished`, `pauseAll`, `updateSettings`.

### Models (`Models.swift`)
- `DownloadStatus`: `queued, downloading, paused, done, failed, stopped`
- `DownloadItem` (`Identifiable`, `Codable`): id, url, title, uploader, thumbnailURL, durationStr, status, progress (0…1), speedStr, etaStr, formatDesc, errorMessage, pid (transient), downloadedBytes, totalBytes, outputFilePath, addedAt, pausedByUser.
- `AppSettings` (`Codable`): destinationFolder, formatSelection (preset string), maxConcurrent, autoGrabClipboard, autoUpdateYTDLP, sponsorBlock, embedMetadata, embedSubs, addToFinderTags. Defaults sensible.
- `SidebarPage`: `queue, history, settings`.

### ClipboardMonitor (`ClipboardMonitor.swift`)
Polls `NSPasteboard.general` string every ~1.2s via a timer on a background queue. Tracks last-seen change count to detect new copies. Extracts URLs from the string (handles surrounding whitespace / multiple lines). Pre-filters via `SupportedURLs.looksSupported(url)` (fast host check) to avoid spamming yt-dlp for arbitrary text. Calls back `onCandidate(url)` on the main thread. Honors `settings.autoGrabClipboard`.

### SupportedURLs (`SupportedURLs.swift`)
Curated host/regex list covering major yt-dlp extractors (YouTube, youtu.be, Vimeo, Twitch, Twitter/X, Instagram, TikTok, SoundCloud, Bandcamp, Dailymotion, Streamable, Reddit, Facebook, Bilibili, etc.). Fast pre-filter only; the authoritative check is `yt-dlp --simulate`.

### YTDLPController (`YTDLP.swift`)
Resolves the active yt-dlp binary path (Application Support copy if present, else bundled fallback; ensures AS copy exists on first launch). Provides:
- `currentVersion() -> String` (`yt-dlp --version`)
- `simulate(url) -> MetaData?` — runs `yt-dlp --simulate --no-warnings --no-playlist --print "META\t%(title)s\t%(uploader)s\t%(thumbnail)s\t%(duration_string)s" <url>`. Returns parsed metadata or nil (unsupported/unavailable).
- `startDownload(item, settings, onProgress, onLog, onDone) -> pid` — spawns `yt-dlp` with: `-o dest/%(title)s.%(ext)s`, `-f <formatSelection>`, `--newline`, `--no-playlist`, `--progress-template "download:DJ %(progress)j"`, `--progress-template "postprocess:PJ %(progress)j"`, `--print "after_move:FILEPATH:%(filepath)s"`, plus optional `--sponsorblock-remove`, `--embed-metadata`, `--embed-subs`. Streams stdout line-by-line on a background thread, parses `DJ`/`PJ` JSON progress and `FILEPATH:` final path.
- `signalTree(pid, signal)` — collects descendants via `pgrep -P` (BFS) and sends the signal to the pid and all descendants. Used for pause (SIGSTOP), resume (SIGCONT), stop (SIGTERM→SIGKILL).

### DownloadManager (`DownloadManager.swift`)
Owns a `DispatchQueue`. Enforces `maxConcurrent`. On any state change, scans for `queued` items and starts them up to the limit. Implements pause (SIGSTOP tree + mark paused), resume (SIGCONT tree + re-mark downloading), stop (SIGTERM tree, mark stopped), retry (stop if running, reset to queued), removeItem (stop if running, drop from list), deleteFile (trash `outputFilePath` via `FileManager.trashItem`, then drop), clearFinished (move `done` items to history, drop from queue), pauseAll.

### Updater (`Updater.swift`)
On launch (background), reads current version, fetches `https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest`, compares `tag_name` (e.g. `2026.03.17`). If newer, downloads the `yt-dlp_macos` asset to a temp file, `chmod +x`, atomically swaps the AS copy (write temp → rename), re-verifies version. Publishes status to AppState (`updaterStatus`). Non-blocking; failures are logged and shown in Settings but never crash.

### SettingsStore (`SettingsStore.swift`)
`ObservableObject` backed by a JSON file at `~/Library/Application Support/YTGrabber/settings.json`. Persists `AppSettings` and the queue/history (`queue.json`). Loads on init, writes on change (debounced).

## Data Flow

1. User copies a URL → `ClipboardMonitor` detects new pasteboard change.
2. `SupportedURLs.looksSupported` fast pre-filter; if pass, `AppState.addCandidate`.
3. `YTDLPController.simulate` runs async; if it returns metadata, a `DownloadItem` (status `queued`) is appended (and persisted). If it fails, the URL is skipped (counted as `skipped`).
4. `DownloadManager` sees a `queued` item and, under the concurrency limit, calls `YTDLPController.startDownload`.
5. Progress lines stream back → item updated on main thread → SwiftUI re-renders rows (progress bar, speed, ETA, status badge).
6. User controls (pause/resume/stop/retry/clear/delete) call `AppState` → `DownloadManager` → signals/respawns.
7. On completion (`FILEPATH:` line + process exit 0) → status `done`, file path stored, item moves to history on `clearFinished`.

## Settings (UI)
- Destination folder (picker + reveal-in-Finder).
- Default format preset: Best (mp4), 1080p, 720p, Audio only (m4a), Custom `-f` string.
- Concurrent downloads (1–4).
- Auto-grab clipboard (on/off) + global hotkey info.
- Auto-update yt-dlp on launch (on/off) + manual "Check now" + current version display.
- SponsorBlock remove, Embed metadata, Embed subtitles.
- yt-dlp binary path + updater status.

## Per-item controls
pause · resume · stop · retry · reveal in Finder · remove from list · delete downloaded file. Toolbar: **Clear done** (finished items), **Pause all**, **＋ Paste URL**.

## Packaging
`build.sh`:
1. Download `yt-dlp_macos` from latest GitHub release into `Resources/bin/yt-dlp`; `chmod +x`.
2. `swiftc -O -target arm64-apple-macos14 -framework SwiftUI -framework AppKit -framework Foundation` all sources → `YTGrabber.app/Contents/MacOS/YTGrabber`.
3. Place `Info.plist`, bundle `yt-dlp` into `Contents/Resources/bin/yt-dlp` (fallback), app icon.
4. `codesign -s -` (ad-hoc) so it runs locally.
5. `pkgbuild --root <payload> --install-location /Applications --identifier com.bpenven.ytgrabber --version <v> YTGrabber-<v>.pkg` (payload root contains `YTGrabber.app`).
6. `productbuild` with a `Distribution.xml` (welcome + readme + license optional) for a polished installer.

> Not notarized (local use). For distribution, add notarization + a developer ID signature step.

## Non-goals (v1)
Browser extension integration, playlist UI editing, accounts/cookies UI, universal binary (arm64 only), Sparkle app-self-update (only yt-dlp auto-updates).

## Risks
- `--simulate` makes a network call per clipboard URL; mitigated by host pre-filter and 1.2s poll cadence.
- SIGSTOP pause is process-level; ffmpeg merge (postprocess) is short and rare during active pause.
- Unsigned PKG requires Gatekeeper bypass (`xattr -cr` or right-click open) — noted in README.