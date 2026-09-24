"""Build the Windows .exe with PyInstaller and zip it for release.

Run on Windows (or windows-latest CI):
    pip install -r requirements.txt
    python build.py

Produces dist/TapeNexus/ (a folder app) and dist/TapeNexus-<ver>-win64.zip.
The yt-dlp.exe + ffmpeg.exe + ffprobe.exe are downloaded and bundled so the
app works out of the box without a network fetch on first run.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(ROOT, "tapenexus", "bin")
# Single source of truth for the runtime version is tapenexus.__version__;
# CI overrides via TN_VERSION (set to the release tag). Default to the package
# version so the two can't drift when building locally.
try:
    from tapenexus import __version__ as _PKG_VERSION
    _DEFAULT_VERSION = _PKG_VERSION
except Exception:
    _DEFAULT_VERSION = "1.0.18"
VERSION = os.environ.get("TN_VERSION", _DEFAULT_VERSION).lstrip("vV")


def _download(url: str, dest: str) -> None:
    print(f"  > {url}")
    urllib.request.urlretrieve(url, dest)


def _prepare_sync() -> str:
    """Return the path to a `sync.json` to bake into the .exe.

    Precedence (matches the macOS build.sh baking sync.local.json):
      1. TN_SUPABASE_URL + TN_SUPABASE_ANON_KEY env vars — set on CI from
         repository secrets. Lets the Windows build ship cloud sync without
         the gitignored creds ever entering the repo.
      2. tapenexus/sync.local.json — local dev override (gitignored).
      3. tapenexus/sync.json — the committed empty template (sync disabled).

    The file is always bundled under the name `sync.json` (PyInstaller keeps
    the source basename), so sync_manager._bundled_sync_path() — which looks
    for sync.json in _MEIPASS — finds it. (Previously sync.local.json was
    bundled under its own name and never matched, so local Windows builds
    silently shipped with sync disabled.)
    """
    import json as _json
    build_tmp = os.path.join(ROOT, "build_tmp")
    os.makedirs(build_tmp, exist_ok=True)
    out = os.path.join(build_tmp, "sync.json")

    env_url = os.environ.get("TN_SUPABASE_URL", "").strip()
    env_key = os.environ.get("TN_SUPABASE_ANON_KEY", "").strip()
    if env_url and env_key:
        print(">> Baking cloud-sync config from TN_SUPABASE_* env (CI secrets)…")
        with open(out, "w", encoding="utf-8") as fh:
            _json.dump({"url": env_url, "anonKey": env_key}, fh, indent=2)
        return out

    local = os.path.join(ROOT, "tapenexus", "sync.local.json")
    if os.path.isfile(local):
        print(">> Baking cloud-sync config from gitignored sync.local.json…")
        shutil.copyfile(local, out)
        return out

    # Empty template — sync disabled at runtime.
    return os.path.join(ROOT, "tapenexus", "sync.json")


def ensure_binaries() -> None:
    os.makedirs(BIN, exist_ok=True)
    ytdlp = os.path.join(BIN, "yt-dlp.exe")
    if not os.path.isfile(ytdlp):
        print(">> Downloading yt-dlp.exe...")
        _download("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", ytdlp)

    # ffmpeg + ffprobe from BtbN's Windows GPL build (zip with bin/*.exe)
    if not all(os.path.isfile(os.path.join(BIN, n)) for n in ("ffmpeg.exe", "ffprobe.exe")):
        print(">> Downloading ffmpeg + ffprobe (BtbN Windows GPL)...")
        url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        tmp = tempfile.mkdtemp()
        zp = os.path.join(tmp, "ffmpeg.zip")
        _download(url, zp)
        with zipfile.ZipFile(zp) as z:
            for member in z.namelist():
                base = os.path.basename(member).lower()
                if base in ("ffmpeg.exe", "ffprobe.exe"):
                    with z.open(member) as src, open(os.path.join(BIN, base), "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    print(f"  extracted {base}")
        shutil.rmtree(tmp, ignore_errors=True)


def build() -> None:
    ensure_binaries()
    print(">> Running PyInstaller (onefile)...")
    sep = ";" if os.name == "nt" else ":"
    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm", "--clean", "--windowed", "--onefile",
        "--name", "TapeNexus",
        "--distpath", os.path.join(ROOT, "dist"),
        "--workpath", os.path.join(ROOT, "build_tmp"),
        "--specpath", os.path.join(ROOT, "build_tmp"),
        # Absolute source path: with --specpath set, PyInstaller resolves
        # relative --add-data sources against the spec dir (build_tmp), not
        # CWD, so a relative "tapenexus/bin" would not be found.
        "--add-data", os.path.join(ROOT, "tapenexus", "bin") + sep + "bin",
        # Cloud-sync config (Supabase URL + publishable key). Materialized by
        # _prepare_sync() from CI secrets / sync.local.json / the empty
        # template, always bundled as `sync.json` so the runtime finds it.
        "--add-data", _prepare_sync() + sep + ".",
        "--collect-all", "PySide6",
        "--hidden-import", "PySide6.QtNetwork",
        "--hidden-import", "PySide6.QtWidgets",
        "--hidden-import", "PySide6.QtGui",
        "--hidden-import", "psutil",
        "run.py",
    ]
    subprocess.check_call(cmd)

    # --onefile produces a single dist/TapeNexus.exe; stamp it with the version.
    dist = os.path.join(ROOT, "dist")
    built = os.path.join(dist, "TapeNexus.exe")
    out = os.path.join(dist, f"TapeNexus-{VERSION}-win64.exe")
    if os.path.exists(out):
        os.remove(out)
    shutil.move(built, out)
    print(f"OK: {out}")


if __name__ == "__main__":
    build()