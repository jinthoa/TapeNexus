# Tape Nexus — Windows port

A native Windows port of Tape Nexus, built with Python + PySide6 and frozen to a
standalone `.exe` with PyInstaller. Same idea as the macOS app: watch the
clipboard, queue any URL yt-dlp supports, download through `yt-dlp.exe`, with a
dashboard UI and full per-item control.

## Get the prebuilt exe

Download `TapeNexus-<ver>-win64.exe` from the
[latest release](https://github.com/jinthoa/TapeNexus/releases/latest) and
run it — a single portable executable. `yt-dlp.exe`, `ffmpeg.exe`, and
`ffprobe.exe` are bundled inside — no separate install needed.

The first launch takes a few seconds: PyInstaller extracts the bundled
payload (Qt libs + binaries) to a temp folder before the window opens.

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

Produces `dist/TapeNexus-<ver>-win64.exe` — a single portable executable
(PyInstaller `--onefile --windowed`). `build.py` downloads and bundles
`yt-dlp.exe` + `ffmpeg.exe` + `ffprobe.exe` inside it.

## How it's built on CI

The `.github/workflows/build-windows.yml` workflow builds the `.exe` on
`windows-latest` (free for public repos) whenever a `v*` tag is pushed, and
attaches the single `.exe` to that release. So the Windows binary is produced
without anyone needing a Windows machine locally.

## Feature parity with v1.0.5 (macOS)

- Clipboard auto-grab + paste + drag-and-drop (URLs or a `.txt` file)
- Queue with All / Active / Done / Failed filter, live progress, speed, ETA;
  **Retry all** re-queues every failed/stopped item in one click; "Clear done"
  removes finished items
- Per-item pause / resume / stop / retry / reveal / remove / delete file
  (pause/resume use `psutil` process suspend/resume — Windows has no SIGSTOP)
- Per-item format picker + time-range clip editor on queued rows
- **Format preview** — "Show available formats…" runs `--list-formats` and lists
  every resolution / bitrate / size the link offers; picking one applies it as a
  custom `-f`
- **Per-item scheduling** — schedule a queued item to start at a later time, on
  top of global quiet hours; the scheduler re-checks every minute
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
  build.py                 download binaries + PyInstaller --onefile
  requirements.txt
```

Note: the Windows port is feature-equivalent but is a separate codebase from the
Swift/AppKit macOS app — SwiftUI/AppKit don't exist on Windows, so the GUI is
reimplemented in PySide6 rather than shared.