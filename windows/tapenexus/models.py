"""Data models, format presets, and the supported-host pre-filter for Tape Nexus (Windows)."""
from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime
from enum import Enum
from typing import List


class DownloadStatus(str, Enum):
    resolving = "resolving"
    queued = "queued"
    downloading = "downloading"
    paused = "paused"
    done = "done"
    failed = "failed"
    stopped = "stopped"


# (key, label, -f arg, audio-extract format or None)
FORMAT_PRESETS: List[tuple] = [
    ("best", "Best (mp4)", "bestvideo*+bestaudio/best", None),
    ("1080p", "Up to 1080p", "bestvideo[height<=1080]+bestaudio/best[height<=1080]", None),
    ("720p", "Up to 720p", "bestvideo[height<=720]+bestaudio/best[height<=720]", None),
    ("audio", "Audio only (m4a)", "bestaudio/best", None),
    ("mp3", "Audio only (MP3)", "bestaudio/best", "mp3"),
    ("custom", "Custom…", "", None),
]

COOKIE_BROWSERS = [
    ("", "None"),
    ("chrome", "Chrome"),
    ("edge", "Edge"),
    ("firefox", "Firefox"),
    ("brave", "Brave"),
    ("chromium", "Chromium"),
    ("safari", "Safari"),
    ("vivaldi", "Vivaldi"),
    ("opera", "Opera"),
]


def format_arg(preset: str, custom: str) -> str:
    if not preset:
        return "bestvideo*+bestaudio/best"
    if preset == "custom":
        return custom or "bestvideo*+bestaudio/best"
    for k, _label, arg, _ext in FORMAT_PRESETS:
        if k == preset:
            return arg or "bestvideo*+bestaudio/best"
    return "bestvideo*+bestaudio/best"


def format_label(preset: str, custom: str) -> str:
    if not preset:
        return ""
    if preset == "custom":
        return f"custom: {custom}"
    for k, label, _arg, _ext in FORMAT_PRESETS:
        if k == preset:
            return label
    return "Best"


def audio_extract_format(preset: str):
    for k, _label, _arg, ext in FORMAT_PRESETS:
        if k == preset:
            return ext
    return None


@dataclass
class DownloadItem:
    id: str
    url: str
    title: str = ""
    uploader: str = ""
    thumbnail: str = ""
    duration_str: str = ""
    status: str = "queued"
    progress: float = 0.0
    speed_str: str = ""
    eta_str: str = ""
    format_desc: str = ""
    error_message: str = ""
    downloaded_bytes: int = 0
    total_bytes: int = 0
    output_file_path: str = ""
    added_at: str = ""
    paused_by_user: bool = False
    format_preset: str = ""
    custom_format: str = ""
    clip_start: str = ""
    clip_end: str = ""
    # v1.0.4: per-item scheduling (ISO string, "" = start whenever a slot is free)
    start_at: str = ""

    # transient (not persisted)
    pid: int = 0

    @staticmethod
    def new(url: str, format_desc: str = "") -> "DownloadItem":
        return DownloadItem(
            id=str(uuid.uuid4()),
            url=url,
            status="resolving",
            format_desc=format_desc,
            added_at=datetime.now().isoformat(),
        )

    @property
    def display_title(self) -> str:
        return self.title or self.url

    @property
    def host(self) -> str:
        m = re.match(r"https?://([^/]+)", self.url)
        if not m:
            return self.url
        h = m.group(1).lower()
        return h[4:] if h.startswith("www.") else h

    @property
    def has_clip(self) -> bool:
        return bool(self.clip_start or self.clip_end)

    @property
    def has_schedule(self) -> bool:
        return bool(self.start_at)

    @property
    def schedule_ready(self) -> bool:
        """True if no schedule is set, or the scheduled start time has passed."""
        if not self.start_at:
            return True
        try:
            return datetime.fromisoformat(self.start_at) <= datetime.now()
        except Exception:
            return True

    def to_dict(self) -> dict:
        d = asdict(self)
        d.pop("pid", None)
        return d

    @staticmethod
    def from_dict(d: dict) -> "DownloadItem":
        d = {k: v for k, v in d.items() if k in DownloadItem.__dataclass_fields__}
        return DownloadItem(**d)


@dataclass
class AppSettings:
    destination_folder: str = ""
    format_preset: str = "1080p"
    custom_format: str = "bestvideo*+bestaudio/best"
    max_concurrent: int = 2
    auto_grab_clipboard: bool = True
    auto_start_downloads: bool = False
    auto_update_ytdlp: bool = True
    sponsor_block: bool = False
    embed_metadata: bool = True
    embed_subs: bool = False
    poll_interval_seconds: float = 1.2
    subtitle_langs: str = "en,.*,auto"
    cookies_browser: str = ""
    organize_by_host: bool = False
    expand_playlists: bool = False
    playlist_cap: int = 50
    notify_on_complete: bool = True
    quiet_hours_enabled: bool = False
    quiet_start: int = 23
    quiet_end: int = 7

    @staticmethod
    def default() -> "AppSettings":
        import os
        dest = os.path.join(os.path.expanduser("~"), "Downloads", "YT")
        return AppSettings(destination_folder=dest)


# Cheap host pre-filter (same idea as the macOS app) so we don't fire yt-dlp at
# arbitrary copied text.
SUPPORTED_HOSTS = {
    "youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com",
    "vimeo.com", "player.vimeo.com",
    "twitch.tv", "m.twitch.tv", "clips.twitch.tv",
    "twitter.com", "x.com", "mobile.twitter.com",
    "instagram.com",
    "tiktok.com", "vm.tiktok.com",
    "soundcloud.com", "bandcamp.com",
    "dailymotion.com", "dai.ly", "streamable.com",
    "reddit.com", "old.reddit.com", "v.redd.it", "redd.it",
    "facebook.com", "fb.watch", "m.facebook.com",
    "bilibili.com", "b23.tv",
    "pinterest.com", "pin.it", "tumblr.com",
    "dropbox.com", "mega.nz", "mega.co.nz",
    "open.spotify.com", "podcasts.apple.com",
    "patreon.com", "kick.com", "rumble.com", "bitchute.com",
    "media.ccc.de", "peertube.tv", "odysee.com",
    "media.giphy.com", "flickr.com", "artstation.com",
}

_URL_RE = re.compile(r"https?://[^\s<>\"')\]]+")


def extract_urls(text: str) -> List[str]:
    return [m.group(0) for m in _URL_RE.finditer(text or "")]


def looks_supported(raw: str) -> bool:
    m = re.match(r"https?://([^/]+)", raw)
    if not m:
        return False
    host = m.group(1).lower()
    clean = host[4:] if host.startswith("www.") else host
    if clean in SUPPORTED_HOSTS or host in SUPPORTED_HOSTS:
        return True
    return any(clean.endswith("." + h) for h in SUPPORTED_HOSTS)


def looks_like_playlist(url: str) -> bool:
    l = (url or "").lower()
    return "list=" in l or "/playlist" in l or "playlist?" in l


# ── v1.0.4: format preview ──────────────────────────────────────────────────


@dataclass
class FormatInfo:
    """One row of yt-dlp's --list-formats output, parsed for the preview picker."""
    id: str
    ext: str
    resolution: str = ""
    size_str: str = ""
    tbr: str = ""
    kind: str = "mixed"  # "video" | "audio" | "mixed"

    @property
    def kind_label(self) -> str:
        return {"video": "video", "audio": "audio", "mixed": "mixed"}.get(self.kind, self.kind)

    @property
    def summary(self) -> str:
        parts = [self.id, self.ext]
        if self.resolution:
            parts.append(self.resolution)
        if self.tbr:
            parts.append(self.tbr)
        if self.size_str:
            parts.append(self.size_str)
        return " · ".join(p for p in parts if p)

    @property
    def format_arg(self) -> str:
        # video-only format → merge with bestaudio; audio/mixed → use as-is
        if self.kind == "video":
            return f"{self.id}+bestaudio/best"
        return self.id