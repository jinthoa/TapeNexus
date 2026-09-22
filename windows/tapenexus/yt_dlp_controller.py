"""Resolves and drives the bundled yt-dlp.exe + ffmpeg.exe on Windows."""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from typing import List, Optional, Tuple

from .models import AppSettings, DownloadItem, format_arg, audio_extract_format


APP_NAME = "TapeNexus"


def _appdata_bin_dir() -> str:
    base = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), APP_NAME, "bin")
    os.makedirs(base, exist_ok=True)
    return base


def _bundled_dir() -> str:
    """Resources dir next to the frozen exe or the source package."""
    if getattr(sys, "frozen", False):
        return os.path.join(os.path.dirname(sys.executable), "bin")
    return os.path.join(os.path.dirname(__file__), "bin")


def _resolve(name: str) -> Optional[str]:
    """Return the path to a binary: writable AppData copy first, then bundled."""
    appdata = os.path.join(_appdata_bin_dir(), name)
    if os.path.isfile(appdata):
        return appdata
    bundled = os.path.join(_bundled_dir(), name)
    if os.path.isfile(bundled):
        # seed the AppData copy so the updater has a writable home
        try:
            shutil.copy2(bundled, appdata)
            os.chmod(appdata, 0o755)
            return appdata
        except Exception:
            return bundled
    return appdata  # may not exist yet; commands will fail gracefully


class YTDLPController:
    def __init__(self) -> None:
        self._dj_seen = 0

    @property
    def binary(self) -> str:
        return _resolve("yt-dlp.exe")

    @property
    def ffmpeg_dir(self) -> str:
        # Ensure ffmpeg.exe + ffprobe.exe live in the AppData bin dir.
        d = _appdata_bin_dir()
        for name in ("ffmpeg.exe", "ffprobe.exe"):
            dest = os.path.join(d, name)
            bundled = os.path.join(_bundled_dir(), name)
            if not os.path.isfile(dest) and os.path.isfile(bundled):
                try:
                    shutil.copy2(bundled, dest)
                    os.chmod(dest, 0o755)
                except Exception:
                    pass
        return d

    def ensure_binaries(self) -> None:
        if not os.path.isfile(self.binary):
            self._download_ytdlp()
        for name in ("ffmpeg.exe", "ffprobe.exe"):
            if not os.path.isfile(os.path.join(self.ffmpeg_dir, name)):
                self._download_ffmpeg()

    # ── downloads ────────────────────────────────────────────────────────────
    def _download_ytdlp(self) -> None:
        url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
        try:
            urllib.request.urlretrieve(url, self.binary)
            os.chmod(self.binary, 0o755)
        except Exception:
            pass

    def _download_ffmpeg(self) -> None:
        # BtbN's Windows GPL build: a zip with bin/ffmpeg.exe + bin/ffprobe.exe.
        url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        d = self.ffmpeg_dir
        try:
            tmp = tempfile.mkdtemp()
            zp = os.path.join(tmp, "ffmpeg.zip")
            urllib.request.urlretrieve(url, zp)
            with zipfile.ZipFile(zp) as z:
                # find the two exes anywhere in the archive
                for member in z.namelist():
                    base = os.path.basename(member).lower()
                    if base in ("ffmpeg.exe", "ffprobe.exe"):
                        with z.open(member) as src, open(os.path.join(d, base), "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        os.chmod(os.path.join(d, base), 0o755)
        except Exception:
            pass

    # ── version / simulate / playlist ─────────────────────────────────────────
    def _run(self, args: List[str], timeout: int = 60) -> Tuple[int, str, str]:
        try:
            p = subprocess.run(
                [self.binary] + args,
                capture_output=True, text=True, timeout=timeout,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
            return p.returncode, p.stdout, p.stderr
        except Exception as e:
            return -1, "", str(e)

    def current_version(self) -> str:
        code, out, _ = self._run(["--version"], timeout=15)
        if code != 0:
            return ""
        return (out.strip().splitlines() or [""])[0]

    def simulate(self, url: str):
        """Return ('success', VideoMeta) | 'unsupported' | ('failed', msg)."""
        sep = "\x1f"
        tmpl = f"META{sep}%(title)s{sep}%(uploader)s{sep}%(thumbnail)s{sep}%(duration_string)s"
        code, out, err = self._run(
            ["--simulate", "--no-warnings", "--no-playlist", "--print", tmpl, url], timeout=25
        )
        if code == 0:
            line = out.strip()
            parts = line.split(sep)
            if len(parts) >= 5 and line.startswith("META"):
                return ("success", {
                    "title": parts[1], "uploader": parts[2],
                    "thumbnail": parts[3], "duration_str": parts[4],
                })
            return ("failed", "No metadata returned")
        combined = (err or "") + (out or "")
        if "Unsupported URL" in combined:
            return ("unsupported",)
        lines = [l for l in combined.splitlines() if l.strip()]
        msg = lines[0].strip() if lines else f"yt-dlp exited {code}"
        return ("failed", msg)

    def simulate_playlist(self, url: str, cap: int) -> Optional[List[str]]:
        code, out, _ = self._run(
            ["--flat-playlist", "--no-warnings", "--print", "%(url)s", url], timeout=45
        )
        if code != 0:
            return None
        entries = [l.strip() for l in out.splitlines()
                   if l.strip() and l.strip().startswith("http")]
        if not entries:
            return None
        return entries[: max(1, cap)]

    # ── download args ──────────────────────────────────────────────────────────
    def build_args(self, item: DownloadItem, settings: AppSettings) -> List[str]:
        preset = item.format_preset or settings.format_preset
        custom = item.custom_format if item.format_preset else settings.custom_format
        dest = settings.destination_folder
        out_tpl = (f"{dest}/%(extractor)s/%(title)s.%(ext)s"
                   if settings.organize_by_host else f"{dest}/%(title)s.%(ext)s")
        args = [
            "--newline", "--progress", "--no-playlist", "--no-mtime",
            "--ffmpeg-location", self.ffmpeg_dir,
            "-f", format_arg(preset, custom),
            "-o", out_tpl,
            "--progress-template", "download:DJ %(progress)j",
            "--progress-template", "postprocess:PJ %(progress)j",
            "--print", "after_move:FILEPATH:%(filepath)s",
        ]
        if settings.cookies_browser:
            args += ["--cookies-from-browser", settings.cookies_browser]
        if item.has_clip:
            start = item.clip_start or "0"
            if not item.clip_end:
                section = f"*{start}-inf"
            elif not item.clip_start:
                section = f"*0-{item.clip_end}"
            else:
                section = f"*{start}-{item.clip_end}"
            args += ["--download-sections", section, "--force-keyframes-at-cuts"]
        ext = audio_extract_format(preset)
        if ext:
            args += ["--extract-audio", "--audio-format", ext]
        if settings.sponsor_block:
            args += ["--sponsorblock-remove", "default"]
        if settings.embed_metadata:
            args += ["--embed-metadata"]
        if settings.embed_subs:
            langs = settings.subtitle_langs or "en,.*,auto"
            args += ["--write-subs", "--embed-subs", "--sub-langs", langs]
        args.append(item.url)
        return args

    # ── progress parsing ─────────────────────────────────────────────────────
    @staticmethod
    def parse_stdout(line: str):
        """Return one of: ('dj', pct, speed, eta, dl, tot) | ('file', path) | ('log', line)."""
        t = line.strip()
        if not t:
            return None
        if t.startswith("DJ ") or t.startswith("PJ "):
            try:
                obj = json.loads(t[3:])
            except Exception:
                return None
            pct = obj.get("_percent") or obj.get("percentage") or 0
            dl = int(obj.get("downloaded_bytes") or 0)
            tot = (int(obj.get("total_bytes") or 0)
                   or int(obj.get("total_bytes_estimate") or 0))
            speed = obj.get("speed") or 0
            eta = obj.get("eta") or 0
            return ("dj", pct / 100.0, speed, eta, dl, tot)
        if t.startswith("FILEPATH:"):
            return ("file", t[len("FILEPATH:"):].strip())
        return ("log", t)

    @staticmethod
    def format_speed(bps: float) -> str:
        if bps <= 0:
            return ""
        units = ["B/s", "KB/s", "MB/s", "GB/s"]
        v, i = bps, 0
        while v > 1024 and i < len(units) - 1:
            v /= 1024
            i += 1
        return f"{v:.1f} {units[i]}"

    @staticmethod
    def format_eta(sec: float) -> str:
        s = int(sec)
        if s <= 0:
            return ""
        if s < 60:
            return f"{s}s"
        if s < 3600:
            return f"{s // 60}m{s % 60:02d}s"
        return f"{s // 3600}h{(s % 3600) // 60:02d}m"