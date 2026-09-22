# Tape Nexus — Windows port

A native Windows port of Tape Nexus, built with Python + PySide6 and frozen to a
standalone `.exe` with PyInstaller. Same idea as the macOS app: watch the
clipboard, queue any URL yt-dlp supports, download through `yt-dlp.exe`, with a
dashboard UI and full per-item control.

## Get the prebuilt exe

Download `TapeNexus-<ver>-win64.zip` from the
[latest release](https://github.com/jinthoa/TapeNexus/releases/latest),
unzip it anywhere, and run `TapeNexus.exe`. `yt-dlp.exe`, `ffmpeg.exe`, and
`ffprobe.exe` are bundled — no separate install needed.

Windows SmartScreen may warn on first launch (unsigned). Click **More info →
Run anyway**. This is the Windows equivalent of the macOS quarantine clear.

## Run from source

```powershell
cd windows
pip install -r requirements.txt
python -m tapenexus
```

On first run the app downloads `yt-dlp.exe` + `ffmpeg.exe` into
`%APPDATA%\TapeNexus\bin` if they aren't bundled next to the package.

## Build the exe yourself

```powershell
cd windows
pip install -r requirements.txt
pip install pyinstaller
python build.py
```

Produces `dist/TapeNexus/` (a folder app) and `dist/TapeNexus-<ver>-win64.zip`.
`build.py` downloads and bundles `yt-dlp.exe` + `ffmpeg.exe` + `ffprobe.exe`.

## How it's built on CI

The `.github/workflows/build-windows.yml` workflow builds the `.exe` on
`windows-latest` (free for public repos) whenever a `v*` tag is pushed, and
attaches the `.zip` to that release. So the Windows binary is produced without
anyone needing a Windows machine locally.

## Feature parity with v1.0.3 (macOS)

- Clipboard auto-grab + paste + drag-and-drop (URLs or a `.txt` file)
- Queue with All / Active / Done / Failed filter, live progress, speed, ETA
- Per-item pause / resume / stop / retry / reveal / remove / delete file
  (pause/resume use `psutil` process suspend/resume — Windows has no SIGSTOP)
- Per-item format picker + time-range clip editor on queued rows
- Format presets incl. **Audio only (MP3)** (`--extract-audio --audio-format mp3`)
- Cookies from browser, playlist expansion, per-host organization, subtitle
  language picker, quiet hours, completion notifications (tray), system-tray icon
- Persistence (`%APPDATA%\TapeNexus\settings.json`, `queue.json`)

## Layout

```
windows/
  tapenexus/
    __main__.py            entry point
    app_state.py           queue, scheduler, lifecycle, persistence
    yt_dlp_controller.py   yt-dlp.exe wrapper + progress parsing
    clipboard_monitor.py   Qt clipboard polling
    models.py              dataclasses, presets, host pre-filter
    views/                 main_window, queue_row, settings_dialog, theme
  run.py                   PyInstaller entry shim
  build.py                 download binaries + PyInstaller + zip
  requirements.txt
```

Note: the Windows port is feature-equivalent but is a separate codebase from the
Swift/AppKit macOS app — SwiftUI/AppKit don't exist on Windows, so the GUI is
reimplemented in PySide6 rather than shared.