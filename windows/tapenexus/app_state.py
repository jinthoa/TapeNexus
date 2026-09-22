"""Central application state: queue, settings, download lifecycle, scheduler.

A QObject that owns the yt-dlp controller, clipboard monitor, per-download
QProcess workers, and persistence. UI updates flow through Qt signals.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
from datetime import datetime
from typing import Dict, List, Optional

import psutil
from PySide6.QtCore import QObject, QProcess, QTimer, Signal

from .clipboard_monitor import ClipboardMonitor
from .models import (
    AppSettings, DownloadItem, FormatInfo, extract_urls, format_label,
    looks_like_playlist,
)
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
                self.log.emit(self.item_id, t)

    def _handle(self, line: str) -> None:
        parsed = YTDLPController.parse_stdout(line)
        if not parsed:
            return
        tag = parsed[0]
        if tag == "dj":
            _, pct, speed, eta, dl, tot = parsed
            self.progress.emit(self.item_id, pct,
                               YTDLPController.format_speed(speed),
                               YTDLPController.format_eta(eta), dl, tot)
        elif tag == "file":
            self.filepath.emit(self.item_id, parsed[1])
        elif tag == "log":
            self.log.emit(self.item_id, parsed[1])

    def _on_finished(self, code, _status) -> None:
        ok = code == 0
        self.finished.emit(self.item_id, ok, "" if ok else f"yt-dlp exited with code {code}")


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

    def __init__(self) -> None:
        super().__init__()
        self.yt = YTDLPController()
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
        self._tray = None
        self._quiet_timer = QTimer(self)
        self._quiet_timer.timeout.connect(self._quiet_tick)
        self._quiet_active = False
        self._quiet_paused_ids: set = set()

        self._load()

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

        self._quiet_timer.start(60_000)
        QTimer.singleShot(1000, self._evaluate_quiet_hours)

    # ── persistence ─────────────────────────────────────────────────────────
    def _appdata_file(self, name: str) -> str:
        return os.path.join(_appdata_dir(), name)

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
            self.items = [DownloadItem.from_dict(d) for d in snap.get("queue", [])
                          if d.get("status") not in ("downloading", "paused")]
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
            for u in urls:
                self.add_candidate(u, start_immediately=True)

    def add_urls(self, urls: List[str], start_immediately: bool = True) -> None:
        for u in urls:
            self.add_candidate(u, start_immediately=start_immediately)

    def _on_candidate(self, url: str) -> None:
        self.add_candidate(url, start_immediately=self.settings.auto_start_downloads)

    def add_candidate(self, url: str, start_immediately: bool = None) -> None:
        if any(it.url == url for it in self.items):
            return
        if start_immediately is None:
            start_immediately = self.settings.auto_start_downloads
        item = DownloadItem.new(
            url,
            format_desc=format_label(self.settings.format_preset, self.settings.custom_format),
        )
        item.status = "resolving"
        self.items.insert(0, item)
        self.list_changed.emit()
        self._persist_queue()
        self._verify(item.id, url, start_immediately)

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
        def work():
            result = self.yt.simulate(url)
            QTimer.singleShot(0, lambda: self._on_simulate_done(item_id, url, result, start))
        threading.Thread(target=work, daemon=True).start()

    def _verify_playlist(self, item_id: str, url: str, start: bool) -> None:
        cap = self.settings.playlist_cap
        def work():
            entries = self.yt.simulate_playlist(url, cap)
            QTimer.singleShot(0, lambda: self._on_playlist_done(item_id, url, entries, start))
        threading.Thread(target=work, daemon=True).start()

    def _on_simulate_done(self, item_id, url, result, start) -> None:
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

    def _on_playlist_done(self, item_id, url, entries, start) -> None:
        if self.item(item_id) is None:
            return
        if entries and len(entries) > 1:
            self._remove(item_id)
            for e in entries:
                self.add_candidate(e, start_immediately=start)
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

    def pump_scheduled(self) -> None:
        if self.is_quiet_hour():
            return
        running = sum(1 for it in self.items if it.status == "downloading")
        slots = max(0, self.settings.max_concurrent - running)
        if slots <= 0:
            return
        to_start = [it for it in self.items
                    if it.status == "queued" and it.has_schedule and it.schedule_ready][:slots]
        for it in to_start:
            self._start(it)

    def pump(self) -> None:
        if self.is_quiet_hour():
            return
        running = sum(1 for it in self.items if it.status == "downloading")
        slots = max(0, self.settings.max_concurrent - running)
        if slots <= 0:
            return
        # Only start queued items whose scheduled start time (if any) has come.
        to_start = [it for it in self.items
                    if it.status == "queued" and it.schedule_ready][:slots]
        for it in to_start:
            self._start(it)

    # ── download lifecycle ──────────────────────────────────────────────────
    def _start(self, item: DownloadItem) -> None:
        args = self.yt.build_args(item, self.settings)
        worker = DownloadWorker(item.id, self.yt.binary, args)
        worker.progress.connect(self._on_progress)
        worker.filepath.connect(self._on_filepath)
        worker.log.connect(self._on_log)
        worker.finished.connect(self._on_complete)
        worker.started_pid.connect(lambda iid, pid: self.update(iid, pid=pid))
        self._workers[item.id] = worker
        self.update(item.id, status="downloading", progress=0.0, speed_str="",
                    eta_str="", error_message="")
        worker.start()

    def _on_progress(self, item_id, norm, speed, eta, dl, tot) -> None:
        self.update(item_id, progress=norm, speed_str=speed, eta_str=eta,
                    downloaded_bytes=dl, total_bytes=tot)

    def _on_filepath(self, item_id, path) -> None:
        self.update(item_id, output_file_path=path)

    def _on_log(self, item_id, line) -> None:
        if "ERROR" in line or "Unsupported URL" in line:
            it = self.item(item_id)
            if it and not it.error_message:
                self.update(item_id, error_message=line)

    def _on_complete(self, item_id, ok, err) -> None:
        it = self.item(item_id)
        if it is None:
            self._workers.pop(item_id, None)
            return
        if ok:
            self.update(item_id, status="done", progress=1.0, error_message="", pid=0)
            self._persist_queue()
        else:
            if it.status == "downloading":
                self.update(item_id, status="failed", error_message=err, pid=0)
        self._workers.pop(item_id, None)
        # notify
        finished_it = self.item(item_id)
        if finished_it and self.settings.notify_on_complete and self._tray:
            title = "Download complete" if ok else "Download failed"
            self._tray.showMessage(title, finished_it.display_title)
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
        w = self._workers.pop(item_id, None)
        if w:
            try:
                w.proc.kill()
            except Exception:
                pass
        self.update(item_id, status="stopped", pid=0)
        self._persist_queue()

    def retry(self, item_id: str) -> None:
        it = self.item(item_id)
        if not it:
            return
        if it.status in ("downloading", "paused"):
            self.stop(item_id)
        self.update(item_id, status="queued", progress=0.0, error_message="",
                    speed_str="", eta_str="", downloaded_bytes=0, total_bytes=0, pid=0)
        self._persist_queue()
        self.pump()

    def start_now(self, item_id: str) -> None:
        it = self.item(item_id)
        if it and it.status == "queued":
            self._start(it)

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
        self.list_changed.emit()
        self._persist_queue()

    def retry_all(self) -> None:
        """Re-queue every failed (and stopped) item in one go."""
        for it in list(self.items):
            if it.status in ("failed", "stopped"):
                self.retry(it.id)

    def _remove(self, item_id: str) -> None:
        self.items = [it for it in self.items if it.id != item_id]
        self._workers.pop(item_id, None)
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

        def work() -> None:
            result = self.yt.list_formats(url)
            QTimer.singleShot(0, lambda: self._on_formats_done(item_id, result))

        threading.Thread(target=work, daemon=True).start()

    def _on_formats_done(self, item_id: str, result) -> None:
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