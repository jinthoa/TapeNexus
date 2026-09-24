"""Persistent, local download stats + unlocked achievements.

Fun/motivational only for now — stored per-machine under %APPDATA%/TapeNexus;
a future account system can claim and merge these so they follow the user.
Mirrors Sources/TapeNexus/Achievements.swift on the macOS side.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import List, Optional, Set

_GIB = 1024 ** 3
_TIB = 1024 ** 4


@dataclass
class AchievementStats:
    total_completed: int = 0
    total_bytes: int = 0
    unlocked_ids: Set[str] = field(default_factory=set)
    first_completed_at: Optional[str] = None  # ISO 8601, or None
    night_owl: bool = False
    early_bird: bool = False

    def to_dict(self) -> dict:
        return {
            "total_completed": self.total_completed,
            "total_bytes": self.total_bytes,
            "unlocked_ids": sorted(self.unlocked_ids),
            "first_completed_at": self.first_completed_at,
            "night_owl": self.night_owl,
            "early_bird": self.early_bird,
        }

    @staticmethod
    def from_dict(d: dict) -> "AchievementStats":
        return AchievementStats(
            total_completed=int(d.get("total_completed", 0)),
            total_bytes=int(d.get("total_bytes", 0)),
            unlocked_ids=set(d.get("unlocked_ids", []) or []),
            first_completed_at=d.get("first_completed_at"),
            night_owl=bool(d.get("night_owl", False)),
            early_bird=bool(d.get("early_bird", False)),
        )


class Achievement(str, Enum):
    firstTape = "firstTape"
    mixtape = "mixtape"
    archivist = "archivist"
    centurion = "centurion"
    dataHoarder = "dataHoarder"
    terabyteClub = "terabyteClub"
    nightOwl = "nightOwl"
    earlyBird = "earlyBird"

    @property
    def title(self) -> str:
        return {
            Achievement.firstTape: "First Tape",
            Achievement.mixtape: "Mixtape",
            Achievement.archivist: "Archivist",
            Achievement.centurion: "Centurion",
            Achievement.dataHoarder: "Data Hoarder",
            Achievement.terabyteClub: "Terabyte Club",
            Achievement.nightOwl: "Night Owl",
            Achievement.earlyBird: "Early Bird",
        }[self]

    @property
    def subtitle(self) -> str:
        return {
            Achievement.firstTape: "Finish your first download.",
            Achievement.mixtape: "Finish 10 downloads.",
            Achievement.archivist: "Finish 50 downloads.",
            Achievement.centurion: "Finish 100 downloads.",
            Achievement.dataHoarder: "Download 100 GB in total.",
            Achievement.terabyteClub: "Download 1 TB in total.",
            Achievement.nightOwl: "Finish a download between midnight and 5am.",
            Achievement.earlyBird: "Finish a download between 5am and 10am.",
        }[self]

    @property
    def symbol(self) -> str:
        # No SF Symbols on Windows — use a compact glyph per badge.
        return {
            Achievement.firstTape: "▶",
            Achievement.mixtape: "🎵",
            Achievement.archivist: "🗄",
            Achievement.centurion: "💯",
            Achievement.dataHoarder: "💾",
            Achievement.terabyteClub: "☁",
            Achievement.nightOwl: "🌙",
            Achievement.earlyBird: "🌅",
        }[self]

    def is_unlocked(self, s: AchievementStats) -> bool:
        if self is Achievement.firstTape:
            return s.total_completed >= 1
        if self is Achievement.mixtape:
            return s.total_completed >= 10
        if self is Achievement.archivist:
            return s.total_completed >= 50
        if self is Achievement.centurion:
            return s.total_completed >= 100
        if self is Achievement.dataHoarder:
            return s.total_bytes >= 100 * _GIB
        if self is Achievement.terabyteClub:
            return s.total_bytes >= _TIB
        if self is Achievement.nightOwl:
            return s.night_owl
        if self is Achievement.earlyBird:
            return s.early_bird
        return False


class AchievementsManager:
    """Owns the stats, persists them to achievements.json, and tallies
    completions — returning any badges a completion newly unlocks so the
    caller can fire a tray notification per unlock."""

    def __init__(self, support_dir: str) -> None:
        self._path = os.path.join(support_dir, "achievements.json")
        self.stats = self._load()

    def _load(self) -> AchievementStats:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                return AchievementStats.from_dict(json.load(fh))
        except Exception:
            return AchievementStats()

    def _save(self) -> None:
        try:
            with open(self._path, "w", encoding="utf-8") as fh:
                json.dump(self.stats.to_dict(), fh, indent=2, sort_keys=True)
        except Exception:
            pass

    @property
    def formatted_total_bytes(self) -> str:
        n = float(self.stats.total_bytes)
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024.0 or unit == "TB":
                if unit == "B":
                    return f"{int(n)} {unit}"
                return f"{n:.1f} {unit}"
            n /= 1024.0
        return f"{self.stats.total_bytes} B"

    def is_unlocked(self, a: Achievement) -> bool:
        return a.value in self.stats.unlocked_ids

    def record_completion(self, total_bytes: int) -> List[Achievement]:
        """Record a completed download; return any achievements unlocked by it
        (so the caller can fire a notification per newly-unlocked badge)."""
        s = self.stats
        s.total_completed += 1
        if total_bytes > 0:
            s.total_bytes += total_bytes
        if s.first_completed_at is None:
            s.first_completed_at = datetime.now().isoformat()
        hour = datetime.now().hour
        if 0 <= hour <= 4:
            s.night_owl = True
        if 5 <= hour <= 9:
            s.early_bird = True
        newly: List[Achievement] = []
        for a in Achievement:
            if a.value not in s.unlocked_ids and a.is_unlocked(s):
                s.unlocked_ids.add(a.value)
                newly.append(a)
        if newly:
            self._save()
        return newly

    def merge(self, remote: "AchievementStats") -> None:
        """Merge a remote (server) snapshot into local stats so achievements
        converge across machines: union unlocked badges, take the larger tally,
        OR the time-of-day flags, keep the earliest first-completed timestamp."""
        s = self.stats
        s.total_completed = max(s.total_completed, remote.total_completed)
        s.total_bytes = max(s.total_bytes, remote.total_bytes)
        s.unlocked_ids = set(s.unlocked_ids) | set(remote.unlocked_ids)
        s.night_owl = bool(s.night_owl or remote.night_owl)
        s.early_bird = bool(s.early_bird or remote.early_bird)
        if remote.first_completed_at:
            if s.first_completed_at:
                s.first_completed_at = min(s.first_completed_at, remote.first_completed_at)
            else:
                s.first_completed_at = remote.first_completed_at
        self._save()