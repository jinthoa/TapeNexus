"""App self-update: check GitHub for a newer Tape Nexus release and, on user
request, download the new win64 .exe and relaunch it.

Mirrors the macOS AppUpdater.swift. The yt-dlp / ffmpeg binary updater in
yt_dlp_controller.py is a separate concern (bundled binaries, not the app
itself).

All network calls here are blocking (urllib) and meant to run on a background
thread; the Qt side (AppState) marshals results onto the main thread via signals.
"""
from __future__ import annotations

import os
import subprocess
import urllib.request
from typing import Optional, Tuple

REPO = "jinthoa/TapeNexus"


def current_version() -> str:
    try:
        from . import __version__
        return __version__
    except Exception:
        return "0"


def _fetch_latest_tag() -> Optional[str]:
    """Resolve the latest release tag WITHOUT the GitHub REST API.

    api.github.com is rate-limited to 60 req/hr per IP (unauthenticated); a
    shared NAT/VPN exhausts that fast, a 403 body fails to parse as a release,
    and the app reports "Could not reach GitHub." Instead hit the HTML endpoint
    github.com/<repo>/releases/latest, which 302-redirects to
    .../releases/tag/<tag> (NOT rate-limited). urllib follows the redirect and
    the final URL's last path segment is the tag (e.g. "v1.0.12"). We don't need
    the body, so a HEAD-ish GET that we discard is fine.
    """
    url = f"https://github.com/{REPO}/releases/latest"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "TapeNexus"})
        with urllib.request.urlopen(req, timeout=20) as r:
            final = r.geturl()  # final URL after all redirects
        tag = final.rstrip("/").rsplit("/", 1)[-1]
        return tag or None
    except Exception:
        return None


def _is_newer(latest: str, current: str) -> bool:
    def parts(s: str):
        s = s.lstrip("vV")
        out = []
        for p in s.split("."):
            try:
                out.append(int(p))
            except Exception:
                out.append(0)
        return out
    l, c = parts(latest), parts(current)
    n = max(len(l), len(c))
    for i in range(n):
        lv = l[i] if i < len(l) else 0
        cv = c[i] if i < len(c) else 0
        if lv != cv:
            return lv > cv
    return False


def check_latest() -> Optional[Tuple[str, str]]:
    """Return (latest_tag, exe_asset_url) if a newer release exists, else None.
    Runs a blocking GitHub call - invoke from a background thread.

    The exe asset URL is predictable: releases/download/<tag>/TapeNexus-<ver>-win64.exe,
    so no API/release-asset enumeration is needed.
    """
    tag = _fetch_latest_tag()
    if not tag:
        return None
    if not _is_newer(tag, current_version()):
        return None
    ver = tag.lstrip("vV")
    exe_url = f"https://github.com/{REPO}/releases/download/{tag}/TapeNexus-{ver}-win64.exe"
    return (tag, exe_url)


def download_and_relaunch(exe_url: str, latest_tag: str) -> Tuple[bool, str]:
    """Download the new .exe to the user's Downloads folder and launch it as a
    new process. Returns (ok, message). On success the caller should quit the
    current app so the new version takes over. The old .exe at its original
    location is left in place (replace it manually later if you keep a copy
    somewhere specific)."""
    try:
        downloads = os.path.join(os.environ.get("USERPROFILE", os.path.expanduser("~")), "Downloads")
        os.makedirs(downloads, exist_ok=True)
        fname = f"TapeNexus-{latest_tag.lstrip('vV')}-win64.exe"
        dest = os.path.join(downloads, fname)
        req = urllib.request.Request(exe_url, headers={"User-Agent": "TapeNexus"})
        with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
            f.write(r.read())
        # Launch the new .exe as an independent process (survives this app's quit).
        subprocess.Popen([dest])
        return (True, f"Launched Tape Nexus {latest_tag} from your Downloads folder. "
                "This window will close to finish the update.")
    except Exception as e:
        return (False, f"Update failed: {e}")