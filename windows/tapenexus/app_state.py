"""Central application state: queue, settings, download lifecycle, scheduler.

A QObject that owns the yt-dlp controller, clipboard monitor, per-download
QProcess workers, and persistence. UI updates flow through Qt signals.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from typing import Dict, List, Optional

import psutil
from PySide6.QtCore import QObject, QProcess, QTimer, Signal, Slot

from .achievements import Achievement, AchievementsManager
from .clipboard_monitor import ClipboardMonitor
from .library_manager import LibraryManager
from .subscription_manager import SubscriptionManager
from .models import (
    AppSettings, DownloadItem, FormatInfo, extract_urls, format_label,
    looks_like_playlist,
)
from .sync_manager import SyncManager
from .yt_dlp_controller import YTDLPController

APP_NAME = "TapeNexus"


def _appdata_dir() -> str:
    base = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), APP_NAME)
    os.makedirs(base, exist_ok=True)
    return base


class DownloadWorker(QObject):
    """Wraps a single yt-dlp QProcess and emits parsed signals."""
    progress = Signal(str, float, str, str, int, int)  # id, norm, speed, eta, dl, tot
    filepath = Signal(str, str)
    log = Signal(str, str)
    finished = Signal(str, bool, str)
    started_pid = Signal(str, int)

    def __init__(self, item_id: str, binary: str, args: List[str]) -> None:
        super().__init__()
        self.item_id = item_id
        self.proc = QProcess(self)
        self.proc.setProgram(binary)
        self.proc.setArguments(args)
        self._buf_out = ""
        self._buf_err = ""
        self._last_err = ""  # last yt-dlp ERROR line, to surface as the failure reason
        # Temp .part file paths yt-dlp is writing, captured from progress JSON
        # (tmpfilename) so a stopped download can delete its partial files.
        self.part_files: List[str] = []
        self.proc.readyReadStandardOutput.connect(self._on_out)
        self.proc.readyReadStandardError.connect(self._on_err)
        self.proc.finished.connect(self._on_finished)

    def start(self) -> None:
        self.proc.start()
        # processId() is valid once started; emit on the next tick.
        QTimer.singleShot(0, lambda: self.started_pid.emit(self.item_id, self.proc.processId()))

    def pid(self) -> int:
        return int(self.proc.processId()) if self.proc.processId() else 0

    def _drain(self, channel) -> str:
        return bytes(channel()).decode("utf-8", "replace")

    def _on_out(self) -> None:
        self._buf_out += self._drain(self.proc.readAllStandardOutput)
        while "\n" in self._buf_out:
            line, self._buf_out = self._buf_out.split("\n", 1)
            self._handle(line)

    def _on_err(self) -> None:
        self._buf_err += self._drain(self.proc.readAllStandardError)
        while "\n" in self._buf_err:
            line, self._buf_err = self._buf_err.split("\n", 1)
            t = line.strip()
            if t and not ("% of" in t and "ETA" in t):
                if t.startswith("ERROR"):
                    self._last_err = t
                self.log.emit(self.item_id, t)

    def _handle(self, line: str) -> None:
        parsed = YTDLPController.parse_stdout(line)
        if not parsed:
            return
        tag = parsed[0]
        if tag == "dj":
            _, pct, speed, eta, dl, tot, tmp = parsed
            self.progress.emit(self.item_id, pct,
                               YTDLPController.format_speed(speed),
                               YTDLPController.format_eta(eta), dl, tot)
            if tmp and tmp not in self.part_files:
                self.part_files.append(tmp)
        elif tag == "file":
            self.filepath.emit(self.item_id, parsed[1])
        elif tag == "log":
            self.log.emit(self.item_id, parsed[1])

    def _on_finished(self, code, _status) -> None:
        ok = code == 0
        err = "" if ok else (self._last_err or f"yt-dlp exited with code {code}")
        self.finished.emit(self.item_id, ok, err)


def _suspend_tree(pid: int) -> None:
    try:
        p = psutil.Process(pid)
        p.suspend()
        for c in p.children(recursive=True):
            c.suspend()
    except Exception:
        pass


def _resume_tree(pid: int) -> None:
    try:
        p = psutil.Process(pid)
        p.resume()
        for c in p.children(recursive=True):
            c.resume()
    except Exception:
        pass


class AppState(QObject):
    item_changed = Signal(str)
    list_changed = Signal()
    skipped_changed = Signal(int)
    settings_changed = Signal()
    # App self-update: emitted on launch when a newer release is found
    # (latest_tag, exe_asset_url); and when a download+relaunch finishes
    # (ok, message).
    app_update_available = Signal(str, str)
    app_update_done = Signal(bool, str)
    # Post-download media tools: transient status banner text (or "" to clear).
    media_tool_status = Signal(str)
    simulate_ready = Signal(int, str, str, object, bool)
    playlist_ready = Signal(int, str, str, object, bool)
    subscription_ready = Signal(object)
    formats_ready = Signal(int, str, object)
    update_check_ready = Signal(str, str)
    update_install_ready = Signal(bool, str)

    def __init__(self) -> None:
        super().__init__()
        self.yt = YTDLPController()
        self._media_procs: list = []  # keep QProcess refs alive until finished
        # Local download stats + unlocked badges (fun; per-machine for now).
        self.achievements = AchievementsManager(_appdata_dir())
        # Optional cloud sync (Supabase). Stays local-only when unconfigured.
        self.sync = SyncManager(_appdata_dir())
        self.sync.signed_in_changed.connect(self._on_sync_state_changed)
        # Persistent archive of completed downloads — survives "Clear done".
        # Surfaced as the Library tab; snapshotted from finished queue items.
        self.library = LibraryManager(_appdata_dir())
        # Channel/playlist subscriptions — polled on an interval so new videos
        # auto-queue. Surfaced as the Subscriptions tab.
        self.subscriptions = SubscriptionManager(_appdata_dir())
        self.clipboard = ClipboardMonitor()
        self.items: List[DownloadItem] = []
        self.settings = AppSettings.default()
        self.meta_cache: Dict[str, dict] = {}
        self.skipped_count = 0
        self.paste_field = ""
        self.filter = "all"
        # v1.0.4: format-preview state, keyed by item id
        self.format_lists: Dict[str, list] = {}
        self.formats_loading: set = set()
        self.formats_error: Dict[str, str] = {}

        self._workers: Dict[str, DownloadWorker] = {}
        self._attempt_tokens: Dict[str, object] = {}
        self._tray = None
        self._quiet_timer = QTimer(self)
        self._quiet_timer.timeout.connect(self._quiet_tick)
        self._quiet_active = False
        self._quiet_paused_ids: set = set()
        # Throttled pool for --simulate metadata probes, bounded by
        # max_concurrent so a playlist / batch-paste doesn't fire N probes at
        # the source site in the same instant and get IP-throttled. Sized
        # from settings after _load() below.
        self._meta_pool: ThreadPoolExecutor = None  # type: ignore[assignment]
        # Timestamp of the most recently scheduled launch, for staggering
        # starts by download_delay_seconds.
        self._last_start_at = None
        # Immediate (undelayed) launches still budgeted in the current start
        # wave. Primed to max_concurrent by start_all()/retry_all() so the
        # first cap's worth of downloads launch together; refills then space
        # out by download_delay_seconds. Transient — not persisted.
        self._burst_remaining = 0
        # Item ids that already retried once without browser cookies after a
        # cookies-read failure, so we don't loop. Transient — not persisted.
        self._cookies_retried: set = set()
        # Per-item nonces for deferred launches; cancel_start drops/rotates a
        # token so a pending QTimer.singleShot knows it was cancelled and skips
        # the launch. Transient — not persisted.
        self._launch_tokens: Dict[str, object] = {}
        # Rotated when a backup restore replaces queue/settings. Worker results
        # captured under an older generation are discarded.
        self._state_generation = 0

        self._load()
        # One-time first-run seed: if there's no library.json yet, import the
        # currently-done queue items so existing users don't lose their history
        # the first time they hit "Clear done".
        self.library.seed(self.items)
        self.achievements.activate_user(
            self.sync.user_id if self.sync.is_signed_in else None)
        if self.sync.is_signed_in:
            self.achievements.record_launch()
        self._meta_pool = ThreadPoolExecutor(
            max_workers=max(1, self.settings.max_concurrent),
            thread_name_prefix="tn-meta")
        self.simulate_ready.connect(self._on_simulate_done)
        self.playlist_ready.connect(self._on_playlist_done)
        self.subscription_ready.connect(self._on_subscription_ready)
        self.formats_ready.connect(self._on_formats_done)
        self.update_check_ready.connect(self._on_update_available)
        self.update_install_ready.connect(self._on_update_install_ready)

        # wire clipboard
        self.clipboard.enabled = self.settings.auto_grab_clipboard
        self.clipboard.set_interval(self.settings.poll_interval_seconds if hasattr(self.settings, "poll_interval_seconds") else 1.2)
        self.clipboard.candidate.connect(self._on_candidate)
        self.clipboard.start()

        # ensure binaries exist (downloads yt-dlp.exe + ffmpeg.exe on first run)
        threading.Thread(target=self.yt.ensure_binaries, daemon=True).start()

        # kick off anything queued from a previous session
        if self.settings.auto_start_downloads:
            QTimer.singleShot(500, self.pump)

        # If cloud sync is configured and we have a saved session, pull the
        # server achievements row and merge it into local (so badges earned on
        # another machine appear here), then push the merged snapshot back.
        if self.sync.is_configured and self.sync.is_signed_in:
            self.sync.pull_and_merge(self.achievements)

        self._quiet_timer.start(60_000)
        QTimer.singleShot(1000, self._evaluate_quiet_hours)

        # App self-update: a few seconds after launch, check GitHub for a newer
        # release. If found, app_update_available fires and the UI offers a
        # Skip / Download and install popup.
        self._pending_update = None  # (latest_tag, exe_url) cached for the popup
        QTimer.singleShot(3000, self._check_app_update)
        # Kick the first subscription pass shortly after launch.
        QTimer.singleShot(8000, self.check_all_subscriptions)

    # ── persistence ─────────────────────────────────────────────────────────
    def _appdata_file(self, name: str) -> str:
        return os.path.join(_appdata_dir(), name)

    @Slot(bool)
    def _on_sync_state_changed(self, signed_in: bool) -> None:
        self.achievements.activate_user(self.sync.user_id if signed_in else None)

    def _load(self) -> None:
        try:
            with open(self._appdata_file("settings.json"), "r", encoding="utf-8") as f:
                data = json.load(f)
            self.settings = AppSettings(**{k: v for k, v in data.items()
                                           if k in AppSettings.__dataclass_fields__})
        except Exception:
            self.settings = AppSettings.default()
        try:
            with open(self._appdata_file("queue.json"), "r", encoding="utf-8") as f:
                snap = json.load(f)
            self.items = []
            for raw in snap.get("queue", []):
                item = DownloadItem.from_dict(raw)
                if item.status in ("downloading", "paused", "resolving"):
                    item.status = "stopped"
                    item.pid = 0
                    item.speed_str = ""
                    item.eta_str = ""
                item.launch_scheduled = False
                item.launch_at_ts = 0.0
                self.items.append(item)
            self.meta_cache = snap.get("meta", {}) or {}
        except Exception:
            self.items, self.meta_cache = [], {}
        os.makedirs(self.settings.destination_folder, exist_ok=True)

    def _persist_settings(self) -> None:
        from dataclasses import asdict
        try:
            with open(self._appdata_file("settings.json"), "w", encoding="utf-8") as f:
                json.dump(asdict(self.settings), f, indent=2)
        except Exception:
            pass

    def _persist_queue(self) -> None:
        snap = {
            "queue": [it.to_dict() for it in self.items],
            "meta": self.meta_cache,
        }
        try:
            with open(self._appdata_file("queue.json"), "w", encoding="utf-8") as f:
                json.dump(snap, f, indent=2)
        except Exception:
            pass

    def can_restore_backup(self) -> bool:
        return not any(it.status in ("downloading", "paused", "resolving")
                       for it in self.items)

    def reload_restored_state(self) -> None:
        """Reload every state file covered by a backup into live memory."""
        self._launch_tokens.clear()
        self._last_start_at = None
        self._burst_remaining = 0
        for item in self.items:
            item.launch_scheduled = False
            item.launch_at_ts = 0.0
        self._state_generation += 1
        self._load()
        self.library.reload()
        self.achievements.reload()
        old = self._meta_pool
        self._meta_pool = ThreadPoolExecutor(
            max_workers=max(1, self.settings.max_concurrent),
            thread_name_prefix="tn-meta")
        if old is not None:
            old.shutdown(wait=False, cancel_futures=True)
        self.clipboard.enabled = self.settings.auto_grab_clipboard
        self.clipboard.set_interval(getattr(self.settings, "poll_interval_seconds", 1.2))
        self.clipboard.start()
        self.settings_changed.emit()
        self.list_changed.emit()

    def set_tray(self, tray) -> None:
        self._tray = tray

    # ── helpers ─────────────────────────────────────────────────────────────
    def _idx(self, item_id: str) -> Optional[int]:
        for i, it in enumerate(self.items):
            if it.id == item_id:
                return i
        return None

    def item(self, item_id: str) -> Optional[DownloadItem]:
        i = self._idx(item_id)
        return self.items[i] if i is not None else None

    def any_item(self, item_id: str) -> Optional[DownloadItem]:
        return self.item(item_id)

    def update(self, item_id: str, **fields) -> None:
        i = self._idx(item_id)
        if i is None:
            return
        for k, v in fields.items():
            setattr(self.items[i], k, v)
        self.item_changed.emit(item_id)

    # ── adding URLs ─────────────────────────────────────────────────────────
    def add_manual_urls(self, text: str) -> None:
        urls = extract_urls(text)
        if not urls:
            t = text.strip()
            if t:
                self.add_candidate(t, start_immediately=True)
        else:
            self.add_many(urls, start_immediately=True)

    def add_urls(self, urls: List[str], start_immediately: bool = True) -> None:
        self.add_many(urls, start_immediately=start_immediately)

    def add_many(self, urls: List[str], start_immediately: bool = True) -> None:
        """Insert a batch as a block at the top (first URL at the very top) and
        submit metadata probes in top-to-bottom order, so a big batch resolves
        top-first — no scrolling to watch progress."""
        seen = {it.url for it in self.items}
        fresh = []
        for u in urls:
            if u not in seen:
                seen.add(u)
                fresh.append(u)
        if not fresh:
            return
        fdesc = format_label(self.settings.format_preset, self.settings.custom_format)
        # Insert in reverse so fresh[0] ends at index 0 (top of the block).
        for u in reversed(fresh):
            item = DownloadItem.new(u, format_desc=fdesc)
            item.status = "resolving"
            self.items.insert(0, item)
        self.list_changed.emit()
        self._persist_queue()
        # Verify in list order (top→bottom); the meta pool is FIFO so the top
        # row is probed first.
        for it in self.items[:len(fresh)]:
            self._verify(it.id, it.url, start_immediately)

    def _on_candidate(self, url: str) -> None:
        self.add_candidate(url, start_immediately=self.settings.auto_start_downloads)

    # ── post-download media tools ─────────────────────────────────────────────
    def run_media_tool(self, args: List[str], out: str, done_msg: str) -> None:
        """Run an ffmpeg recipe on a Library file; emit a status banner and
        reveal the produced file in Explorer on success."""
        ffmpeg = os.path.join(self.yt.ffmpeg_dir, "ffmpeg.exe")
        if not os.path.isfile(ffmpeg):
            self.media_tool_status.emit("Bundled ffmpeg isn't available.")
            return
        self.media_tool_status.emit("Working…")
        proc = QProcess(self)
        proc.setProgram(ffmpeg)
        proc.setArguments(["-y"] + args)
        self._media_procs.append(proc)

        def _finished(code, _status, p=proc, out=out, msg=done_msg):
            try:
                self._media_procs.remove(p)
            except ValueError:
                pass
            p.deleteLater()
            if code == 0 and os.path.isfile(out):
                self.media_tool_status.emit(msg)
                self.library.reveal_path(out)
            else:
                self.media_tool_status.emit("Couldn't process that file (ffmpeg failed).")

        proc.finished.connect(_finished)
        proc.start()

    def add_candidate(self, url: str, start_immediately: bool = None,
                      preset: str = "") -> None:
        if any(it.url == url for it in self.items):
            return
        if start_immediately is None:
            start_immediately = self.settings.auto_start_downloads
        use_preset = preset or self.settings.format_preset
        item = DownloadItem.new(
            url,
            format_desc=format_label(use_preset, self.settings.custom_format
                                     if not preset else ""),
        )
        if preset:
            item.format_preset = preset
        item.status = "resolving"
        self.items.insert(0, item)
        self.list_changed.emit()
        self._persist_queue()
        self._verify(item.id, url, start_immediately)

    # ── subscriptions ────────────────────────────────────────────────────────
    def check_subscription(self, sub_id: str) -> None:
        """Flat-list a subscription's current entries and queue any that aren't
        in the last-seen set. First check is a baseline (records entries, queues
        nothing). Runs the yt-dlp probe on a worker thread."""
        sub = self.subscriptions.get(sub_id)
        if not sub:
            return
        url = sub.url
        known = set(sub.known_urls)
        first_check = not sub.known_urls
        preset = sub.preset
        generation = self._state_generation

        def work() -> None:
            entries = self.yt.simulate_playlist(url, 200) or []
            new_urls = [u for u in entries if u not in known]
            if self._state_generation is generation:
                self.subscription_ready.emit(
                    (generation, sub_id, entries, new_urls, first_check, preset))

        threading.Thread(target=work, daemon=True).start()

    @Slot(object)
    def _on_subscription_ready(self, payload) -> None:
        generation, sub_id, entries, new_urls, first_check, preset = payload
        if generation != self._state_generation:
            return
        self.subscriptions.update(
            sub_id, known_urls=entries,
            last_checked_at=datetime.now().isoformat(),
            last_new_count=0 if first_check else len(new_urls))
        if not first_check:
            for url in new_urls:
                if not any(it.url == url for it in self.items):
                    self.add_candidate(url, start_immediately=True, preset=preset)
            if new_urls and self.sync.is_signed_in:
                self.achievements.record_playlist_expansion()

    def check_all_subscriptions(self) -> None:
        """Check every enabled subscription whose interval has elapsed (or that
        has never been checked). Called by the periodic timer + the Check-all
        button."""
        now = datetime.now()
        for sub in self.subscriptions.subs:
            if not sub.enabled:
                continue
            due = True
            if sub.last_checked_at:
                try:
                    last = datetime.fromisoformat(sub.last_checked_at)
                    due = (now - last).total_seconds() >= sub.interval_minutes * 60
                except Exception:
                    due = True
            if due:
                self.check_subscription(sub.id)

    # ── verify (simulate / playlist) ─────────────────────────────────────────
    def _verify(self, item_id: str, url: str, start: bool) -> None:
        if self.settings.expand_playlists and looks_like_playlist(url):
            self._verify_playlist(item_id, url, start)
            return
        self._verify_single(item_id, url, start)

    def _verify_single(self, item_id: str, url: str, start: bool) -> None:
        cached = self.meta_cache.get(url)
        if cached:
            self._apply_meta(item_id, url, cached, start)
            return
        generation = self._state_generation
        def work():
            result = self.yt.simulate(url)
            if self._state_generation is generation:
                self.simulate_ready.emit(generation, item_id, url, result, start)
        # Bounded pool: no more than max_concurrent metadata probes in flight,
        # so a playlist / batch-paste can't burst the source site.
        self._meta_pool.submit(work)

    def _verify_playlist(self, item_id: str, url: str, start: bool) -> None:
        cap = self.settings.playlist_cap
        generation = self._state_generation
        def work():
            entries = self.yt.simulate_playlist(url, cap)
            if self._state_generation is generation:
                self.playlist_ready.emit(generation, item_id, url, entries, start)
        threading.Thread(target=work, daemon=True).start()

    @Slot(int, str, str, object, bool)
    def _on_simulate_done(self, generation, item_id, url, result, start) -> None:
        if generation != self._state_generation:
            return
        if self.item(item_id) is None:
            return
        kind = result[0]
        if kind == "success":
            meta = result[1]
            self.meta_cache[url] = meta
            self._apply_meta(item_id, url, meta, start)
        elif kind == "unsupported":
            self._remove(item_id)
            self.skipped_count += 1
            self.skipped_changed.emit(self.skipped_count)
            self.clipboard.forget(url)
            self._persist_queue()
        else:
            self.update(item_id, status="failed", error_message=result[1])
            self._persist_queue()

    @Slot(int, str, str, object, bool)
    def _on_playlist_done(self, generation, item_id, url, entries, start) -> None:
        if generation != self._state_generation:
            return
        if self.item(item_id) is None:
            return
        if entries and len(entries) > 1:
            # Replace the playlist placeholder with one row per video, inserted
            # as a block (first entry at top) and probed top-to-bottom — same
            # as a batch paste.
            self._remove(item_id)
            self.add_many(entries, start_immediately=start)
            # Achievements: a playlist was expanded into the queue.
            if self.sync.is_signed_in:
                self.achievements.record_playlist_expansion()
                self.sync.push_achievements(self.achievements.stats)
        else:
            self._verify_single(item_id, url, start)

    def _apply_meta(self, item_id, url, meta, start) -> None:
        self.update(item_id,
                    title=meta.get("title", ""),
                    uploader=meta.get("uploader", ""),
                    thumbnail=meta.get("thumbnail", ""),
                    duration_str=meta.get("duration_str", ""),
                    status="queued")
        self._persist_queue()
        if start:
            self.pump()

    # ── scheduler ───────────────────────────────────────────────────────────
    def is_quiet_hour(self) -> bool:
        if not self.settings.quiet_hours_enabled:
            return False
        h = datetime.now().hour
        s, e = self.settings.quiet_start, self.settings.quiet_end
        if s == e:
            return False
        if s < e:
            return s <= h < e
        return h >= s or h < e

    def _evaluate_quiet_hours(self) -> None:
        q = self.is_quiet_hour()
        if q and not self._quiet_active:
            self._quiet_active = True
            for it in list(self.items):
                if it.status == "downloading":
                    self._quiet_paused_ids.add(it.id)
                    self.pause(it.id)
        elif not q and self._quiet_active:
            self._quiet_active = False
            for pid_ in list(self._quiet_paused_ids):
                it = self.item(pid_)
                if it and it.status == "paused":
                    self.resume(pid_)
            self._quiet_paused_ids.clear()
            self.pump()

    def _quiet_tick(self) -> None:
        self._evaluate_quiet_hours()
        # Only launch items the user explicitly scheduled — NOT a general
        # auto-start. With auto-start off, plain queued items must wait for the
        # user to press Start now; only scheduled ones fire when their time lands.
        self.pump_scheduled()
        # Subscription poll: check_all_subscriptions self-filters by each feed's
        # interval, so a 60s tick is cheap even with many subs.
        self.check_all_subscriptions()

    def pump_scheduled(self) -> None:
        if self.is_quiet_hour():
            return
        running = sum(1 for it in self.items if it.status == "downloading")
        slots = max(0, self.settings.max_concurrent - running)
        if slots <= 0:
            return
        to_start = [it for it in self.items
                    if it.status == "queued" and it.has_schedule and it.schedule_ready
                    and not it.launch_scheduled][:slots]
        self._schedule_starts(to_start)

    def pump(self) -> None:
        if self.is_quiet_hour():
            return
        running = sum(1 for it in self.items if it.status == "downloading")
        slots = max(0, self.settings.max_concurrent - running)
        if slots <= 0:
            return
        # Only start queued items whose scheduled start time (if any) has come,
        # and that don't already have a deferred launch pending.
        to_start = [it for it in self.items
                    if it.status == "queued" and it.schedule_ready
                    and not it.launch_scheduled][:slots]
        self._schedule_starts(to_start)

    def _schedule_starts(self, items: List[DownloadItem]) -> None:
        """Stagger launches by download_delay_seconds so a big queue or rapid
        completions don't hit the source site in a burst. The first
        max_concurrent launches of a start wave (primed by start_all() /
        retry_all()) go immediately so the concurrency cap fills at once; once
        that burst budget is spent, later launches wait so successive starts
        are at least `delay` apart. Each launch re-checks status/quiet/slots at
        fire time."""
        if not items:
            return
        delay = self.settings.download_delay_seconds
        now = datetime.now()
        fire_at = now
        if delay > 0 and self._last_start_at is not None:
            fire_at = max(now, self._last_start_at + timedelta(seconds=delay))
        for it in items:
            # Consume the burst budget first: these launches go immediately so
            # the first cap's worth of downloads start together. Once the
            # budget is exhausted, fall back to the staggered fire time.
            immediate = self._burst_remaining > 0
            if immediate:
                self._burst_remaining -= 1
            when = now if immediate else fire_at
            delta_ms = int((when - now).total_seconds() * 1000) if delay > 0 else 0
            if delta_ms <= 0:
                self._launch_if_queued(it.id)
            else:
                # Mark pending so pump() skips this item while it waits —
                # otherwise a re-pump (clipboard grab, completion) re-selects
                # it and inflates the stagger timing. Record the fire time so
                # the row can show a "Starting in Ns" countdown.
                self.update(it.id, launch_scheduled=True, launch_at_ts=when.timestamp())
                iid = it.id
                token = object()
                self._launch_tokens[iid] = token
                # The callback checks the token before firing so cancel_start
                # (which drops/rotates it) neutralizes a pending countdown.
                QTimer.singleShot(delta_ms, lambda iid=iid, token=token:
                                   self._launch_if_queued(iid, token))
            self._last_start_at = when
            # Only advance the stagger fire time for launches that actually
            # used it — immediate launches shouldn't push the next staggered
            # launch further out.
            if not immediate:
                fire_at = fire_at + timedelta(seconds=delay)

    def _launch_if_queued(self, item_id: str, token: object = None) -> None:
        """Launch one item only if still queued, not in quiet hours, and a slot
        is free. Guards against stale scheduled launches."""
        # If a token was given, skip if the launch was cancelled (or superseded)
        # while we waited — cancel_start drops/rotates the token.
        if token is not None:
            if self._launch_tokens.get(item_id) is not token:
                return
            self._launch_tokens.pop(item_id, None)
        # Clear the pending flag + countdown whether or not we actually launch.
        self.update(item_id, launch_scheduled=False, launch_at_ts=0.0)
        if self.is_quiet_hour():
            return
        it = self.item(item_id)
        if not it or it.status != "queued":
            return
        running = sum(1 for x in self.items if x.status == "downloading")
        if running >= self.settings.max_concurrent:
            return
        self._start(it)

    def start_all(self) -> None:
        """Start every queued item, respecting concurrency + the start delay.
        The first max_concurrent launch simultaneously (filling the cap at
        once); the rest stay queued and are launched by pump() as slots free,
        spaced out by download_delay_seconds."""
        self._burst_remaining = self.settings.max_concurrent
        self.pump()

    # ── download lifecycle ──────────────────────────────────────────────────
    def _start(self, item: DownloadItem, suppress_cookies: bool = False) -> None:
        args = self.yt.build_args(item, self.settings, suppress_cookies=suppress_cookies)
        worker = DownloadWorker(item.id, self.yt.binary, args)
        token = object()
        self._attempt_tokens[item.id] = token
        worker.progress.connect(
            lambda iid, norm, speed, eta, dl, tot, t=token:
                self._on_progress(iid, norm, speed, eta, dl, tot, t))
        worker.filepath.connect(
            lambda iid, path, t=token: self._on_filepath(iid, path, t))
        worker.log.connect(
            lambda iid, line, t=token: self._on_log(iid, line, t))
        worker.finished.connect(
            lambda iid, ok, err, t=token: self._on_complete(iid, ok, err, t))
        worker.started_pid.connect(
            lambda iid, pid, t=token:
                self.update(iid, pid=pid) if self._attempt_tokens.get(iid) is t else None)
        self._workers[item.id] = worker
        self.update(item.id, status="downloading", progress=0.0, speed_str="",
                    eta_str="", error_message="")
        worker.start()

    def _on_progress(self, item_id, norm, speed, eta, dl, tot, token=None) -> None:
        if token is not None and self._attempt_tokens.get(item_id) is not token:
            return
        self.update(item_id, progress=norm, speed_str=speed, eta_str=eta,
                    downloaded_bytes=dl, total_bytes=tot)

    def _on_filepath(self, item_id, path, token=None) -> None:
        if token is not None and self._attempt_tokens.get(item_id) is not token:
            return
        self.update(item_id, output_file_path=path)

    def _on_log(self, item_id, line, token=None) -> None:
        if token is not None and self._attempt_tokens.get(item_id) is not token:
            return
        if "ERROR" in line or "Unsupported URL" in line:
            it = self.item(item_id)
            if it and not it.error_message:
                self.update(item_id, error_message=line)

    def _on_complete(self, item_id, ok, err, token=None) -> None:
        if token is not None and self._attempt_tokens.get(item_id) is not token:
            return
        it = self.item(item_id)
        if it is None:
            self._workers.pop(item_id, None)
            if token is None or self._attempt_tokens.get(item_id) is token:
                self._attempt_tokens.pop(item_id, None)
            return
        # Cookies fallback: if browser cookies were used for this attempt and
        # yt-dlp failed before any download progress (an extraction-time failure
        # — typically it couldn't read the browser's cookie store), retry once
        # without cookies so public content still downloads even when the
        # cookies environment is broken.
        used_cookies = bool(self.settings.cookies_browser) and item_id not in self._cookies_retried
        if not ok and used_cookies and it.progress <= 0.001:
            self._workers.pop(item_id, None)
            self._cookies_retried.add(item_id)
            self._start(it, suppress_cookies=True)
            return
        if ok:
            self.update(item_id, status="done", progress=1.0, error_message="",
                        pid=0, retry_count=0, completed_at=datetime.now().isoformat())
            self._persist_queue()
            # Achievements belong to the active account. Signed-out downloads
            # remain available in the Library without changing account stats.
            if self.sync.is_signed_in:
                unlocked = self.achievements.record_completion(it)
                self.sync.push_achievements(self.achievements.stats)
            else:
                unlocked = []
        else:
            unlocked = []
            if it.status == "downloading":
                self.update(item_id, status="failed", error_message=err, pid=0)
        self._workers.pop(item_id, None)
        if token is None or self._attempt_tokens.get(item_id) is token:
            self._attempt_tokens.pop(item_id, None)
        # Auto-retry: if the item genuinely failed (not user-stopped),
        # auto-retry is on, and the budget isn't spent, re-queue it for another
        # attempt instead of leaving it failed. The start delay (if set) paces
        # the retries via pump()/_schedule_starts().
        finished_it = self.item(item_id)
        if finished_it and finished_it.status == "done":
            # Snapshot into the persistent Library archive so the completed
            # download survives "Clear done" and stays browseable / re-
            # downloadable from the Library tab.
            self.library.archive(finished_it)
        if (not ok and finished_it and finished_it.status == "failed"
                and self.settings.auto_retry_failed
                and finished_it.retry_count < self.settings.max_auto_retries):
            self.update(item_id,
                        retry_count=finished_it.retry_count + 1,
                        status="queued", progress=0.0, error_message="",
                        speed_str="", eta_str="",
                        downloaded_bytes=0, total_bytes=0, pid=0)
            self._persist_queue()
            self.pump()
            return
        # notify (only for genuinely terminal outcomes)
        if finished_it and self.settings.notify_on_complete and self._tray:
            title = "Download complete" if ok else "Download failed"
            self._tray.showMessage(title, finished_it.display_title)
            # Achievement unlock notifications are an account feature — only
            # surface them when the user is signed in.
            if self.sync.is_signed_in:
                for a in unlocked:
                    self._tray.showMessage("🏆 Achievement unlocked",
                                           f"{a.title} — {a.subtitle}")
        self.pump()

    # ── controls ────────────────────────────────────────────────────────────
    def pause(self, item_id: str) -> None:
        it = self.item(item_id)
        if not it or it.status != "downloading":
            return
        w = self._workers.get(item_id)
        if w:
            _suspend_tree(w.pid())
        self.update(item_id, status="paused", paused_by_user=True)
        self._persist_queue()

    def resume(self, item_id: str) -> None:
        it = self.item(item_id)
        if not it or it.status != "paused":
            return
        w = self._workers.get(item_id)
        if w:
            _resume_tree(w.pid())
        self.update(item_id, status="downloading", paused_by_user=False)

    def stop(self, item_id: str) -> None:
        it = self.item(item_id)
        if not it or it.status not in ("downloading", "paused"):
            return
        # Invalidate callbacks and mark stopped before the process emits its
        # completion signal, preventing cookie fallback or auto-retry.
        self._attempt_tokens.pop(item_id, None)
        self.update(item_id, status="stopped", pid=0)
        self._persist_queue()
        w = self._workers.pop(item_id, None)
        if w:
            try:
                w.proc.kill()
                w.proc.waitForFinished(3000)
            except Exception:
                pass
            # Delete the partial .part file(s) yt-dlp was writing so a stopped
            # download doesn't leave disk litter. waitForFinished releases the
            # OS file handle (Windows locks open files) before we remove.
            for p in getattr(w, "part_files", []):
                try:
                    os.remove(p)
                except OSError:
                    pass

    def cancel_start(self, item_id: str) -> None:
        """Cancel a queued item's pending start — a deferred (delay-staggered)
        launch countdown or a future start_at schedule — and park it as
        stopped so pump() won't re-select and re-defer it. The pending
        QTimer is neutralized via the launch token. Retry re-queues it."""
        it = self.item(item_id)
        if not it or it.status != "queued":
            return
        self._launch_tokens.pop(item_id, None)
        self.update(item_id, status="stopped", launch_scheduled=False,
                    launch_at_ts=0.0, start_at="")
        self._persist_queue()

    def retry(self, item_id: str) -> None:
        it = self.item(item_id)
        if not it:
            return
        if it.status in ("downloading", "paused"):
            self.stop(item_id)
        self._cookies_retried.discard(item_id)
        self.update(item_id, status="queued", progress=0.0, error_message="",
                    speed_str="", eta_str="", downloaded_bytes=0, total_bytes=0,
                    pid=0, retry_count=0)
        self._persist_queue()
        self.pump()

    def start_now(self, item_id: str) -> None:
        """Start a single queued item, respecting concurrency + the start delay.
        If a slot is free, schedule it (staggered vs the last launch). If no
        slot is free, leave it queued — pump() on the next completion launches
        it — so starting many never overflows into 'Preparing download…'."""
        it = self.item(item_id)
        if not it or it.status != "queued":
            return
        running = sum(1 for x in self.items if x.status == "downloading")
        if running >= self.settings.max_concurrent:
            return
        self._schedule_starts([it])

    def pause_all(self) -> None:
        for it in list(self.items):
            if it.status == "downloading":
                self.pause(it.id)

    def resume_all(self) -> None:
        for it in list(self.items):
            if it.status == "paused":
                self.resume(it.id)
        self.pump()

    def clear_finished(self) -> None:
        done_ids = {it.id for it in self.items if it.status in ("done", "stopped", "failed")}
        if not done_ids:
            return
        self.items = [it for it in self.items if it.id not in done_ids]
        for iid in done_ids:
            self._cookies_retried.discard(iid)
        self.list_changed.emit()
        self._persist_queue()

    def retry_all(self) -> None:
        """Re-queue every failed (and stopped) item in one go. Like start_all,
        primes the burst so the first max_concurrent retry together."""
        self._burst_remaining = self.settings.max_concurrent
        for it in list(self.items):
            if it.status in ("failed", "stopped"):
                self.retry(it.id)

    def _remove(self, item_id: str) -> None:
        self.items = [it for it in self.items if it.id != item_id]
        self._workers.pop(item_id, None)
        self._cookies_retried.discard(item_id)
        self.list_changed.emit()

    def remove(self, item_id: str) -> None:
        it = self.item(item_id)
        if it and it.status in ("downloading", "paused"):
            self.stop(item_id)
        self._remove(item_id)
        self._persist_queue()

    def delete_file(self, item_id: str) -> None:
        it = self.any_item(item_id)
        if not it or not it.output_file_path:
            return
        try:
            import send2trash
            send2trash.send2trash(it.output_file_path)
        except Exception:
            try:
                os.remove(it.output_file_path)
            except Exception:
                pass
        # Also remove a leftover .part if the item never finished (parity with
        # the macOS deleteFile, which trashes the file and hard-deletes .part).
        if it.status != "done":
            try:
                os.remove(it.output_file_path + ".part")
            except OSError:
                pass
        self.remove(item_id)

    def reveal(self, item_id: str) -> None:
        it = self.any_item(item_id)
        if not it or not it.output_file_path:
            return
        path = it.output_file_path
        try:
            subprocess.Popen(["explorer", "/select,", os.path.abspath(path)])
        except Exception:
            try:
                os.startfile(os.path.dirname(path))  # type: ignore[attr-defined]
            except Exception:
                pass

    # ── per-item overrides ──────────────────────────────────────────────────
    def set_item_format(self, item_id: str, preset: str, custom: str) -> None:
        it = self.item(item_id)
        if not it:
            return
        it.format_preset = preset
        it.custom_format = custom
        it.format_desc = (format_label(self.settings.format_preset, self.settings.custom_format)
                          if not preset else format_label(preset, custom))
        self.item_changed.emit(item_id)
        self._persist_queue()

    def set_item_clip(self, item_id: str, start: str, end: str) -> None:
        it = self.item(item_id)
        if not it:
            return
        it.clip_start = start
        it.clip_end = end
        self.item_changed.emit(item_id)
        self._persist_queue()

    # ── per-item scheduling (v1.0.4) ─────────────────────────────────────────
    def set_item_schedule(self, item_id: str, start_at: str) -> None:
        """Schedule a queued item to start no earlier than `start_at` (ISO).
        Empty string clears it."""
        it = self.item(item_id)
        if not it:
            return
        it.start_at = start_at
        self.item_changed.emit(item_id)
        self._persist_queue()
        if not start_at:
            self.pump()

    # ── format preview (v1.0.4) ──────────────────────────────────────────────
    def load_formats(self, item_id: str) -> None:
        """Fetch yt-dlp's available-format list for an item's URL (async)."""
        if item_id in self.formats_loading:
            return
        it = self.any_item(item_id)
        if it is None:
            return
        self.formats_loading.add(item_id)
        self.formats_error[item_id] = ""
        url = it.url
        generation = self._state_generation

        def work() -> None:
            result = self.yt.list_formats(url)
            if self._state_generation is generation:
                self.formats_ready.emit(generation, item_id, result)

        threading.Thread(target=work, daemon=True).start()

    @Slot(int, str, object)
    def _on_formats_done(self, generation, item_id: str, result) -> None:
        if generation != self._state_generation:
            return
        self.formats_loading.discard(item_id)
        if result:
            self.format_lists[item_id] = result
            self.formats_error[item_id] = ""
        else:
            self.formats_error[item_id] = "Couldn't load formats for this link."
        self.item_changed.emit(item_id)

    def apply_format(self, f: FormatInfo, item_id: str) -> None:
        self.set_item_format(item_id, "custom", f.format_arg)

    # ── settings ────────────────────────────────────────────────────────────
    def update_settings(self, s: AppSettings) -> None:
        self.settings = s
        self._persist_settings()
        os.makedirs(s.destination_folder, exist_ok=True)
        # Resize the metadata-probe pool to the new concurrency limit. In-flight
        # + queued probes on the old pool finish naturally (cancel_futures=False);
        # new probes use the new pool.
        old = self._meta_pool
        self._meta_pool = ThreadPoolExecutor(
            max_workers=max(1, s.max_concurrent), thread_name_prefix="tn-meta")
        if old is not None:
            old.shutdown(wait=False, cancel_futures=False)
        self.clipboard.enabled = s.auto_grab_clipboard
        self.clipboard.set_interval(getattr(s, "poll_interval_seconds", 1.2))
        self.clipboard.start()
        self._evaluate_quiet_hours()
        self.settings_changed.emit()

    # ── counts / filter ─────────────────────────────────────────────────────
    def filtered_items(self) -> List[DownloadItem]:
        bucket = {
            "resolving": "active", "queued": "active", "downloading": "active", "paused": "active",
            "done": "done", "failed": "failed", "stopped": "failed",
        }
        if self.filter == "all":
            return list(self.items)
        return [it for it in self.items if bucket.get(it.status) == self.filter]

    def count_for(self, f: str) -> int:
        prev = self.filter
        self.filter = f
        n = len(self.filtered_items())
        self.filter = prev
        return n

    # ── app self-update ──────────────────────────────────────────────────────
    def _check_app_update(self) -> None:
        """Launch-time check (background thread). Emits app_update_available
        with (latest_tag, exe_url) when a newer release is found."""
        from . import app_updater
        def work():
            result = app_updater.check_latest()
            if result:
                tag, url = result
                self.update_check_ready.emit(tag, url)
        threading.Thread(target=work, daemon=True).start()

    @Slot(str, str)
    def _on_update_available(self, latest_tag: str, exe_url: str) -> None:
        self._pending_update = (latest_tag, exe_url)
        self.app_update_available.emit(latest_tag, exe_url)

    def install_app_update(self) -> None:
        """'Download and install' from the popup: download the new .exe and
        relaunch it (background thread), then emit app_update_done."""
        if not self._pending_update:
            return
        tag, url = self._pending_update
        from . import app_updater
        def work():
            ok, msg = app_updater.download_and_relaunch(url, tag)
            self.update_install_ready.emit(ok, msg)
        threading.Thread(target=work, daemon=True).start()

    @Slot(bool, str)
    def _on_update_install_ready(self, ok: bool, message: str) -> None:
        self.app_update_done.emit(ok, message)
