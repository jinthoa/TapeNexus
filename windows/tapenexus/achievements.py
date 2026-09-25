"""Persistent, local download stats + unlocked achievements.

Fun/motivational, stored per-machine under %APPDATA%/TapeNexus, and synced to
Supabase so they follow the signed-in user across machines. The composite
`score` powers the opt-in global leaderboard.
Mirrors Sources/TapeNexus/Achievements.swift on the macOS side.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, date
from enum import Enum
from typing import List, Optional, Set

_GIB = 1024 ** 3
_TIB = 1024 ** 4


def _day_string(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d")


def _longest_run(days: Set[str]) -> int:
    """Longest run of consecutive calendar days in a set of 'yyyy-MM-dd' strings."""
    if not days:
        return 0
    sorted_days = sorted(days)
    best = run = 1
    for i in range(1, len(sorted_days)):
        try:
            prev = date.fromisoformat(sorted_days[i - 1])
            cur = date.fromisoformat(sorted_days[i])
        except ValueError:
            run = 1
            continue
        if (cur - prev).days == 1:
            run += 1
            best = max(best, run)
        else:
            run = 1
    return best


@dataclass
class AchievementStats:
    total_completed: int = 0
    total_bytes: int = 0
    unlocked_ids: Set[str] = field(default_factory=set)
    first_completed_at: Optional[str] = None  # ISO 8601, or None
    night_owl: bool = False
    early_bird: bool = False

    # v1.0.19 (Achievements 2.0): richer stats so badges + the composite score
    # can be computed. Old achievements.json upgrades cleanly via defaults.
    hosts_seen: Set[str] = field(default_factory=set)
    presets_used: Set[str] = field(default_factory=set)
    completion_days: Set[str] = field(default_factory=set)  # "yyyy-MM-dd"
    did_clip: bool = False
    did_schedule: bool = False
    playlists_expanded: int = 0
    did_retry_recover: bool = False
    weekend_warrior: bool = False
    launches: int = 0                     # app launch count (secret badges, local-only)

    # Leaderboard profile (opt-in). Synced in the same achievements row; the
    # `leaderboard_settings_at` timestamp gives last-write-wins across machines.
    display_name: str = ""
    leaderboard_opt_in: bool = False
    leaderboard_settings_at: Optional[str] = None

    @property
    def best_streak(self) -> int:
        return _longest_run(self.completion_days)

    @property
    def current_streak(self) -> int:
        today = _day_string(datetime.now())
        if today not in self.completion_days:
            return 0
        n = 1
        d = date.today()
        while True:
            prev = d.fromordinal(d.toordinal() - 1)
            if prev.isoformat() in self.completion_days:
                n += 1
                d = prev
            else:
                break
        return n

    @property
    def score(self) -> int:
        """Composite leaderboard score (see AchievementStats.score on macOS)."""
        return (
            self.total_completed * 10
            + min(self.total_bytes // _GIB, 500) * 5
            + len(self.unlocked_ids) * 50
            + len(self.hosts_seen) * 15
            + self.best_streak * 20
        )

    def to_dict(self) -> dict:
        return {
            "total_completed": self.total_completed,
            "total_bytes": self.total_bytes,
            "unlocked_ids": sorted(self.unlocked_ids),
            "first_completed_at": self.first_completed_at,
            "night_owl": self.night_owl,
            "early_bird": self.early_bird,
            "hosts_seen": sorted(self.hosts_seen),
            "presets_used": sorted(self.presets_used),
            "completion_days": sorted(self.completion_days),
            "did_clip": self.did_clip,
            "did_schedule": self.did_schedule,
            "playlists_expanded": self.playlists_expanded,
            "did_retry_recover": self.did_retry_recover,
            "weekend_warrior": self.weekend_warrior,
            "launches": self.launches,
            "display_name": self.display_name,
            "leaderboard_opt_in": self.leaderboard_opt_in,
            "leaderboard_settings_at": self.leaderboard_settings_at,
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
            hosts_seen=set(d.get("hosts_seen", []) or []),
            presets_used=set(d.get("presets_used", []) or []),
            completion_days=set(d.get("completion_days", []) or []),
            did_clip=bool(d.get("did_clip", False)),
            did_schedule=bool(d.get("did_schedule", False)),
            playlists_expanded=int(d.get("playlists_expanded", 0)),
            did_retry_recover=bool(d.get("did_retry_recover", False)),
            weekend_warrior=bool(d.get("weekend_warrior", False)),
            launches=int(d.get("launches", 0)),
            display_name=str(d.get("display_name", "") or ""),
            leaderboard_opt_in=bool(d.get("leaderboard_opt_in", False)),
            leaderboard_settings_at=d.get("leaderboard_settings_at"),
        )


class Achievement(str, Enum):
    firstTape = "firstTape"
    mixtape = "mixtape"
    archivist = "archivist"
    centurion = "centurion"
    collector = "collector"
    librarian = "librarian"
    vaultKeeper = "vaultKeeper"
    dataHoarder = "dataHoarder"
    terabyteClub = "terabyteClub"
    nightOwl = "nightOwl"
    earlyBird = "earlyBird"
    weekendWarrior = "weekendWarrior"
    multiHost = "multiHost"
    globetrotter = "globetrotter"
    audiophile = "audiophile"
    highDef = "highDef"
    clipMaster = "clipMaster"
    planner = "planner"
    playlistPioneer = "playlistPioneer"
    comebackKid = "comebackKid"
    streak3 = "streak3"
    streak7 = "streak7"
    completionist = "completionist"
    # Secret (hidden until unlocked — see `secret`)
    helloWorld = "helloWorld"
    regular = "regular"
    twoHundred = "twoHundred"
    wellRounded = "wellRounded"
    persistent = "persistent"

    @property
    def secret(self) -> bool:
        return self in (
            Achievement.helloWorld, Achievement.regular, Achievement.twoHundred,
            Achievement.wellRounded, Achievement.persistent,
        )

    @property
    def title(self) -> str:
        return {
            Achievement.firstTape: "First Tape",
            Achievement.mixtape: "Mixtape",
            Achievement.archivist: "Archivist",
            Achievement.centurion: "Centurion",
            Achievement.collector: "Collector",
            Achievement.librarian: "Librarian",
            Achievement.vaultKeeper: "Vault Keeper",
            Achievement.dataHoarder: "Data Hoarder",
            Achievement.terabyteClub: "Terabyte Club",
            Achievement.nightOwl: "Night Owl",
            Achievement.earlyBird: "Early Bird",
            Achievement.weekendWarrior: "Weekend Warrior",
            Achievement.multiHost: "Multi-Source",
            Achievement.globetrotter: "Globetrotter",
            Achievement.audiophile: "Audiophile",
            Achievement.highDef: "High Definition",
            Achievement.clipMaster: "Clip Master",
            Achievement.planner: "The Planner",
            Achievement.playlistPioneer: "Playlist Pioneer",
            Achievement.comebackKid: "Comeback Kid",
            Achievement.streak3: "On a Roll",
            Achievement.streak7: "Unstoppable",
            Achievement.completionist: "Completionist",
            Achievement.helloWorld: "Hello, World",
            Achievement.regular: "Regular",
            Achievement.twoHundred: "Double Centurion",
            Achievement.wellRounded: "Well-Rounded",
            Achievement.persistent: "Persistent",
        }[self]

    @property
    def subtitle(self) -> str:
        return {
            Achievement.firstTape: "Finish your first download.",
            Achievement.mixtape: "Finish 10 downloads.",
            Achievement.archivist: "Finish 50 downloads.",
            Achievement.centurion: "Finish 100 downloads.",
            Achievement.collector: "Finish 250 downloads.",
            Achievement.librarian: "Finish 500 downloads.",
            Achievement.vaultKeeper: "Finish 1,000 downloads.",
            Achievement.dataHoarder: "Download 100 GB in total.",
            Achievement.terabyteClub: "Download 1 TB in total.",
            Achievement.nightOwl: "Finish a download between midnight and 5am.",
            Achievement.earlyBird: "Finish a download between 5am and 10am.",
            Achievement.weekendWarrior: "Finish a download on a weekend.",
            Achievement.multiHost: "Download from 3 different sites.",
            Achievement.globetrotter: "Download from 10 different sites.",
            Achievement.audiophile: "Finish an audio-only download.",
            Achievement.highDef: "Finish a 1080p download.",
            Achievement.clipMaster: "Finish a clipped download.",
            Achievement.planner: "Finish a scheduled download.",
            Achievement.playlistPioneer: "Expand a playlist into the queue.",
            Achievement.comebackKid: "Succeed after an auto-retry.",
            Achievement.streak3: "Download 3 days in a row.",
            Achievement.streak7: "Download 7 days in a row.",
            Achievement.completionist: "Unlock every other achievement.",
            Achievement.helloWorld: "Launch Tape Nexus once.",
            Achievement.regular: "Launch Tape Nexus 50 times.",
            Achievement.twoHundred: "Finish 200 downloads.",
            Achievement.wellRounded: "Use 4 different format presets.",
            Achievement.persistent: "Unlock 15 achievements.",
        }[self]

    @property
    def symbol(self) -> str:
        # No SF Symbols on Windows — use a compact glyph per badge.
        return {
            Achievement.firstTape: "▶",
            Achievement.mixtape: "🎵",
            Achievement.archivist: "🗄",
            Achievement.centurion: "💯",
            Achievement.collector: "🗃",
            Achievement.librarian: "📚",
            Achievement.vaultKeeper: "🔒",
            Achievement.dataHoarder: "💾",
            Achievement.terabyteClub: "☁",
            Achievement.nightOwl: "🌙",
            Achievement.earlyBird: "🌅",
            Achievement.weekendWarrior: "📅",
            Achievement.multiHost: "🔗",
            Achievement.globetrotter: "🌐",
            Achievement.audiophile: "〰",
            Achievement.highDef: "🖥",
            Achievement.clipMaster: "✂",
            Achievement.planner: "⏰",
            Achievement.playlistPioneer: "📜",
            Achievement.comebackKid: "↩",
            Achievement.streak3: "🔥",
            Achievement.streak7: "🔥",
            Achievement.completionist: "🏅",
            Achievement.helloWorld: "🖥",
            Achievement.regular: "📅",
            Achievement.twoHundred: "🔢",
            Achievement.wellRounded: "🔲",
            Achievement.persistent: "🎖",
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
        if self is Achievement.collector:
            return s.total_completed >= 250
        if self is Achievement.librarian:
            return s.total_completed >= 500
        if self is Achievement.vaultKeeper:
            return s.total_completed >= 1000
        if self is Achievement.dataHoarder:
            return s.total_bytes >= 100 * _GIB
        if self is Achievement.terabyteClub:
            return s.total_bytes >= _TIB
        if self is Achievement.nightOwl:
            return s.night_owl
        if self is Achievement.earlyBird:
            return s.early_bird
        if self is Achievement.weekendWarrior:
            return s.weekend_warrior
        if self is Achievement.multiHost:
            return len(s.hosts_seen) >= 3
        if self is Achievement.globetrotter:
            return len(s.hosts_seen) >= 10
        if self is Achievement.audiophile:
            return "audio" in s.presets_used or "mp3" in s.presets_used
        if self is Achievement.highDef:
            return "1080p" in s.presets_used or "best" in s.presets_used
        if self is Achievement.clipMaster:
            return s.did_clip
        if self is Achievement.planner:
            return s.did_schedule
        if self is Achievement.playlistPioneer:
            return s.playlists_expanded >= 1
        if self is Achievement.comebackKid:
            return s.did_retry_recover
        if self is Achievement.streak3:
            return s.best_streak >= 3
        if self is Achievement.streak7:
            return s.best_streak >= 7
        if self is Achievement.completionist:
            others = [a for a in Achievement if a is not Achievement.completionist]
            return all(a.value in s.unlocked_ids for a in others)
        if self is Achievement.helloWorld:
            return s.launches >= 1
        if self is Achievement.regular:
            return s.launches >= 50
        if self is Achievement.twoHundred:
            return s.total_completed >= 200
        if self is Achievement.wellRounded:
            return len(s.presets_used) >= 4
        if self is Achievement.persistent:
            others = [a.value for a in Achievement if a is not Achievement.persistent]
            return sum(1 for v in s.unlocked_ids if v in others) >= 15
        return False

    def progress(self, s: "AchievementStats"):
        """For grindy badges, a trackable (current, target, unit) so the UI can
        show a progress bar + '47/50' on locked badges. Returns None for one-shot
        / boolean badges. target is always >= 2 when not None."""
        others_unlocked = sum(
            1 for a in Achievement if a is not self and a.value in s.unlocked_ids)
        if self is Achievement.mixtape:
            return (float(s.total_completed), 10, "")
        if self is Achievement.archivist:
            return (float(s.total_completed), 50, "")
        if self is Achievement.centurion:
            return (float(s.total_completed), 100, "")
        if self is Achievement.collector:
            return (float(s.total_completed), 250, "")
        if self is Achievement.librarian:
            return (float(s.total_completed), 500, "")
        if self is Achievement.vaultKeeper:
            return (float(s.total_completed), 1000, "")
        if self is Achievement.twoHundred:
            return (float(s.total_completed), 200, "")
        if self is Achievement.dataHoarder:
            return (float(s.total_bytes) / float(_GIB), 100, " GB")
        if self is Achievement.terabyteClub:
            return (float(s.total_bytes) / float(_GIB), 1024, " GB")
        if self is Achievement.multiHost:
            return (float(len(s.hosts_seen)), 3, " hosts")
        if self is Achievement.globetrotter:
            return (float(len(s.hosts_seen)), 10, " hosts")
        if self is Achievement.streak3:
            return (float(s.best_streak), 3, " days")
        if self is Achievement.streak7:
            return (float(s.best_streak), 7, " days")
        if self is Achievement.regular:
            return (float(s.launches), 50, "")
        if self is Achievement.wellRounded:
            return (float(len(s.presets_used)), 4, "")
        if self is Achievement.persistent:
            return (float(others_unlocked), 15, "")
        if self is Achievement.completionist:
            return (float(others_unlocked), float(len(list(Achievement)) - 1), "")
        return None


class AchievementsManager:
    """Owns the stats, persists them to achievements.json, and tallies
    completions — returning any badges a completion newly unlocks so the
    caller can fire a tray notification per unlock."""

    def __init__(self, support_dir: str) -> None:
        self._path = os.path.join(support_dir, "achievements.json")
        self._profiles: dict[str, AchievementStats] = {}
        self._legacy: Optional[AchievementStats] = None
        self._active_user: Optional[str] = None
        self.stats = AchievementStats()
        self._load_store()

    def _load_store(self) -> None:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
            if isinstance(raw, dict) and raw.get("version") == 2 and isinstance(raw.get("profiles"), dict):
                self._profiles = {
                    str(uid): AchievementStats.from_dict(value)
                    for uid, value in raw["profiles"].items()
                    if isinstance(value, dict)
                }
                legacy = raw.get("legacy")
                self._legacy = AchievementStats.from_dict(legacy) if isinstance(legacy, dict) else None
            elif isinstance(raw, dict):
                # v1 stored one unscoped profile. Claim it once, when the first
                # authenticated user is activated, rather than copying it into
                # every account that signs in on this installation.
                self._legacy = AchievementStats.from_dict(raw)
        except Exception:
            self._profiles = {}
            self._legacy = None

    def activate_user(self, user_id: Optional[str]) -> None:
        """Switch the visible/persisted stats to one authenticated user.

        Signed-out state is intentionally blank and is never persisted. This
        prevents one person's local activity and leaderboard consent from being
        uploaded when a different account signs in on the same machine.
        """
        if self._active_user:
            self._profiles[self._active_user] = self.stats
        self._active_user = user_id or None
        if not self._active_user:
            self.stats = AchievementStats()
            return
        if self._active_user not in self._profiles:
            self._profiles[self._active_user] = self._legacy or AchievementStats()
            self._legacy = None
        self.stats = self._profiles[self._active_user]
        self.save()

    def reload(self) -> None:
        """Re-read achievements.json from disk. Used after a backup restore so
        a later _save() can't clobber the restored file with old stats."""
        active = self._active_user
        self._profiles = {}
        self._legacy = None
        self._load_store()
        self._active_user = None
        self.activate_user(active)

    def save(self) -> None:
        if not self._active_user:
            return
        self._profiles[self._active_user] = self.stats
        payload = {
            "version": 2,
            "legacy": self._legacy.to_dict() if self._legacy else None,
            "profiles": {uid: stats.to_dict() for uid, stats in self._profiles.items()},
        }
        try:
            with open(self._path, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, indent=2, sort_keys=True)
        except Exception:
            pass

    def _save(self) -> None:
        self.save()

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

    def record_completion(self, item) -> List[Achievement]:
        """Record a completed download; return any achievements unlocked by it.
        Takes the full DownloadItem so host/format/clip/schedule/retry badges
        can fire."""
        s = self.stats
        now = datetime.now()
        s.total_completed += 1
        if item.total_bytes > 0:
            s.total_bytes += item.total_bytes
        if s.first_completed_at is None:
            s.first_completed_at = now.isoformat()
        hour = now.hour
        if 0 <= hour <= 4:
            s.night_owl = True
        if 5 <= hour <= 9:
            s.early_bird = True
        if now.weekday() >= 5:  # Mon=0 .. Sat=5, Sun=6
            s.weekend_warrior = True
        s.hosts_seen.add(item.host())
        if getattr(item, "format_preset", ""):
            s.presets_used.add(item.format_preset)
        s.completion_days.add(_day_string(now))
        if item.has_clip():
            s.did_clip = True
        if item.has_schedule():
            s.did_schedule = True
        if getattr(item, "retry_count", 0) > 0:
            s.did_retry_recover = True
        return self._recompute_unlocked()

    def record_playlist_expansion(self) -> List[Achievement]:
        """Record that a playlist URL was expanded into per-video queue items.
        Returns any achievements unlocked by it."""
        self.stats.playlists_expanded += 1
        return self._recompute_unlocked()

    def record_launch(self) -> List[Achievement]:
        """Record an app launch (called once per startup). Returns any
        achievements unlocked by it; the caller drops them silently (no unlock
        notification at launch — the badges just appear in the popover)."""
        self.stats.launches += 1
        return self._recompute_unlocked()

    def _recompute_unlocked(self) -> List[Achievement]:
        s = self.stats
        newly: List[Achievement] = []
        for a in Achievement:
            if a.value not in s.unlocked_ids and a.is_unlocked(s):
                s.unlocked_ids.add(a.value)
                newly.append(a)
        self._save()  # tallies/days/sets changed regardless of new badges
        return newly

    def set_leaderboard_profile(self, name: str, opt_in: bool) -> None:
        """Set the leaderboard display name + opt-in. Stamps a settings
        timestamp so cross-machine merge can do last-write-wins."""
        self.stats.display_name = name.strip()
        self.stats.leaderboard_opt_in = opt_in
        self.stats.leaderboard_settings_at = datetime.now().isoformat()
        self._save()

    def merge(self, remote: "AchievementStats") -> None:
        """Merge a remote (server) snapshot into local stats so achievements
        converge across machines: union unlocked badges + sets, take the larger
        tally, OR the time-of-day/behavior flags, keep the earliest
        first-completed. Leaderboard profile uses last-write-wins on the
        settings timestamp."""
        s = self.stats
        s.total_completed = max(s.total_completed, remote.total_completed)
        s.total_bytes = max(s.total_bytes, remote.total_bytes)
        s.unlocked_ids = set(s.unlocked_ids) | set(remote.unlocked_ids)
        s.hosts_seen = set(s.hosts_seen) | set(remote.hosts_seen)
        s.presets_used = set(s.presets_used) | set(remote.presets_used)
        s.completion_days = set(s.completion_days) | set(remote.completion_days)
        s.night_owl = bool(s.night_owl or remote.night_owl)
        s.early_bird = bool(s.early_bird or remote.early_bird)
        s.weekend_warrior = bool(s.weekend_warrior or remote.weekend_warrior)
        s.did_clip = bool(s.did_clip or remote.did_clip)
        s.did_schedule = bool(s.did_schedule or remote.did_schedule)
        s.did_retry_recover = bool(s.did_retry_recover or remote.did_retry_recover)
        s.playlists_expanded = max(s.playlists_expanded, remote.playlists_expanded)
        s.launches = max(s.launches, remote.launches)
        if remote.first_completed_at:
            if s.first_completed_at:
                s.first_completed_at = min(s.first_completed_at, remote.first_completed_at)
            else:
                s.first_completed_at = remote.first_completed_at
        # Last-write-wins for the leaderboard profile.
        local_at = s.leaderboard_settings_at
        remote_at = remote.leaderboard_settings_at
        if remote_at and (not local_at or remote_at > local_at):
            s.display_name = remote.display_name
            s.leaderboard_opt_in = remote.leaderboard_opt_in
            s.leaderboard_settings_at = remote_at
        self._save()
