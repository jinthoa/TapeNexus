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
VERSION = os.environ.get("TN_VERSION", "1.0.9").lstrip("vV")


def _download(url: str, dest: str) -> None:
    print(f"  > {url}")
    urllib.request.urlretrieve(url, dest)


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