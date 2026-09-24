"""A single download row: thumbnail, metadata, progress, and per-item controls."""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from PySide6.QtCore import Qt, QUrl, QSize
from PySide6.QtGui import QPixmap, QGuiApplication, QDesktopServices
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkRequest, QNetworkReply
from PySide6.QtWidgets import (
    QSizePolicy, QWidget, QHBoxLayout, QVBoxLayout, QLabel, QProgressBar,
    QPushButton, QComboBox, QDialog, QLineEdit, QFormLayout, QDialogButtonBox,
    QDateTimeEdit, QScrollArea, QFrame, QMessageBox,
)

from ..models import DownloadItem, FORMAT_PRESETS, format_label
from . import theme


class ClipDialog(QDialog):
    def __init__(self, item: DownloadItem, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Download a clip")
        form = QFormLayout(self)
        self.start = QLineEdit(item.clip_start)
        self.end = QLineEdit(item.clip_end)
        self.start.setPlaceholderText("0:00")
        self.end.setPlaceholderText("e.g. 1:30")
        form.addRow("Start", self.start)
        form.addRow("End", self.end)
        hint = QLabel("Timestamps like 1:23 or 83 (seconds). Leave end blank to grab to the end.")
        hint.setWordWrap(True)
        hint.setStyleSheet(f"color: {theme.MUTED};")
        form.addRow(hint)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        if item.has_clip:
            clear = buttons.addButton("Clear", QDialogButtonBox.ResetRole)
            clear.clicked.connect(self._clear)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

    def _clear(self) -> None:
        self.start.setText("")
        self.end.setText("")
        self.accept()

    def values(self):
        return self.start.text().strip(), self.end.text().strip()


class ScheduleDialog(QDialog):
    """Pick a future start time for a queued download (v1.0.4)."""
    def __init__(self, item: DownloadItem, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Schedule download")
        form = QFormLayout(self)
        self.dt = QDateTimeEdit()
        self.dt.setDisplayFormat("yyyy-MM-dd HH:mm")
        self.dt.setCalendarPopup(True)
        if item.start_at:
            try:
                self.dt.setDateTime(datetime.fromisoformat(item.start_at))
            except Exception:
                self.dt.setDateTime(datetime.now())
        else:
            self.dt.setDateTime(datetime.now())
        # don't allow a time in the past
        self.dt.setMinimumDateTime(datetime.now())
        form.addRow("Start at", self.dt)
        hint = QLabel("The download waits in the queue until this time. Clear to start immediately.")
        hint.setWordWrap(True)
        hint.setStyleSheet(f"color: {theme.MUTED};")
        form.addRow(hint)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        if item.start_at:
            clear = buttons.addButton("Clear", QDialogButtonBox.ResetRole)
            clear.clicked.connect(self._clear)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

    def _clear(self) -> None:
        self.dt = None
        self.accept()

    def value(self) -> str:
        if self.dt is None:
            return ""
        return self.dt.dateTime().toPython().isoformat()


class FormatsDialog(QDialog):
    """Shows yt-dlp's available formats for an item and applies the chosen one."""
    SHOW_FORMATS = "__show_formats__"

    def __init__(self, state, item: DownloadItem, parent=None) -> None:
        super().__init__(parent)
        self.state = state
        self.item = item
        self.setWindowTitle("Available formats")
        self.resize(560, 460)
        outer = QVBoxLayout(self)
        title = QLabel(item.display_title)
        title.setWordWrap(True)
        title.setStyleSheet(f"font-weight: 600; color: {theme.TEXT};")
        outer.addWidget(title)
        hint = QLabel(f"{item.host}  ·  pick a format to download")
        hint.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        outer.addWidget(hint)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        host = QWidget()
        self.list_layout = QVBoxLayout(host)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(4)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(host)
        outer.addWidget(self.scroll, 1)

        self._render()
        # refresh once formats load
        state.item_changed.connect(self._on_changed)

    def _on_changed(self, item_id: str) -> None:
        if item_id == self.item.id:
            self._render()

    def _render(self) -> None:
        # clear
        for i in reversed(range(self.list_layout.count() - 1)):
            w = self.list_layout.itemAt(i).widget()
            if w:
                w.deleteLater()
        iid = self.item.id
        if iid in self.state.formats_loading:
            lbl = QLabel("Loading formats…")
            lbl.setStyleSheet(f"color: {theme.MUTED};")
            self.list_layout.insertWidget(0, lbl)
            return
        err = self.state.formats_error.get(iid, "")
        rows = self.state.format_lists.get(iid)
        if err and not rows:
            box = QHBoxLayout()
            box.addWidget(QLabel(err))
            again = QPushButton("Try again")
            again.clicked.connect(lambda: self.state.load_formats(iid))
            box.addStretch(1)
            box.addWidget(again)
            wrap = QWidget(); wrap.setLayout(box)
            self.list_layout.insertWidget(0, wrap)
            return
        if not rows:
            lbl = QLabel("No formats available.")
            lbl.setStyleSheet(f"color: {theme.MUTED};")
            self.list_layout.insertWidget(0, lbl)
            return
        for f in rows:
            self.list_layout.insertWidget(self.list_layout.count() - 1, self._row(f))

    def _row(self, f) -> QFrame:
        frame = QFrame()
        frame.setStyleSheet(
            f"QFrame {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; }}"
            f"QFrame:hover {{ background: #1d2230; }}"
        )
        h = QHBoxLayout(frame)
        h.setContentsMargins(10, 8, 10, 8)
        h.setSpacing(10)
        id_lbl = QLabel(f.id)
        id_lbl.setStyleSheet(f"font-family: Consolas; color: {theme.ACCENT2}; font-weight: 600;")
        id_lbl.setMinimumWidth(70)
        ext = QLabel(f.ext)
        ext.setStyleSheet(f"color: {theme.TEXT};")
        ext.setMinimumWidth(40)
        res = QLabel(f.resolution or "—")
        res.setStyleSheet(f"color: {theme.TEXT};")
        res.setMinimumWidth(90)
        tbr = QLabel(f.tbr or "")
        tbr.setStyleSheet(f"color: {theme.MUTED}; font-family: Consolas;")
        tbr.setMinimumWidth(50)
        size = QLabel(f.size_str or "")
        size.setStyleSheet(f"color: {theme.MUTED}; font-family: Consolas;")
        kind = QLabel(f.kind_label)
        kind.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
        for w in (id_lbl, ext, res, tbr, size, kind):
            h.addWidget(w)
        h.addStretch(1)
        btn = QPushButton("Download")
        btn.setStyleSheet(
            f"QPushButton {{ background: {theme.ACCENT}; color: #0e1014; padding: 4px 10px;"
            f" border-radius: 5px; font-weight: 600; }}"
        )
        btn.clicked.connect(lambda _=False, ff=f: self._pick(ff))
        h.addWidget(btn)
        return frame

    def _pick(self, f) -> None:
        self.state.apply_format(f, self.item.id)
        self.accept()


class QueueRow(QWidget):
    def __init__(self, state, item: DownloadItem) -> None:
        super().__init__()
        self.state = state
        self.item = item
        self.setObjectName("row")
        self.setStyleSheet(theme.ROW_QSS)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        self.nam = QNetworkAccessManager(self)
        self._thumb_reply: Optional[QNetworkReply] = None

        root = QHBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(14)

        # thumbnail
        self.thumb = QLabel()
        self.thumb.setFixedSize(132, 74)
        self.thumb.setAlignment(Qt.AlignCenter)
        self.thumb.setStyleSheet(f"background: #0b0d12; border-radius: 6px; color: {theme.MUTED};")
        self.thumb.setText("·")
        root.addWidget(self.thumb)

        # center column
        center = QVBoxLayout()
        center.setSpacing(6)
        self.title = QLabel(item.display_title)
        self.title.setStyleSheet(f"font-weight: 600; font-size: 13px; color: {theme.TEXT};")
        self.meta = QLabel("")
        self.meta.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        self.status_row = QHBoxLayout()
        self.status_row.setSpacing(8)
        self.badge = QLabel("")
        self.fmt_chip = QLabel("")
        self.clip_chip = QLabel("")
        self.schedule_chip = QLabel("")
        self.progress = QProgressBar()
        self.progress.setFixedWidth(320)
        self.progress.setRange(0, 1000)
        self.progress.setTextVisible(False)
        self.percent = QLabel("")
        self.percent.setStyleSheet(f"color: {theme.MUTED}; font-family: Consolas; font-size: 11px;")
        self.spinner = QLabel("Preparing download…")
        self.spinner.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        self.spinner.hide()
        self.countdown = QLabel("")
        self.countdown.setStyleSheet(f"color: {theme.ACCENT}; font-family: Consolas; font-size: 11px;")
        self.countdown.hide()
        self.retry_badge = QLabel("")
        self.retry_badge.setStyleSheet(f"color: {theme.MUTED}; font-family: Consolas; font-size: 11px;")
        self.retry_badge.hide()
        self.err_label = QLabel("")
        self.err_label.setStyleSheet(f"color: {theme.ERR}; font-size: 10px;")
        self.bytes_label = QLabel("")
        self.bytes_label.setStyleSheet(f"color: {theme.MUTED}; font-family: Consolas; font-size: 10px;")
        for w in (self.badge, self.fmt_chip, self.clip_chip, self.schedule_chip, self.progress, self.percent, self.spinner, self.countdown, self.retry_badge, self.err_label):
            self.status_row.addWidget(w)
        center.addLayout(self.status_row)
        center.addWidget(self.bytes_label)
        center.addWidget(self.meta)
        root.addLayout(center, 1)

        # controls column
        self.controls = QVBoxLayout()
        self.controls.setSpacing(6)
        self.button_row = QHBoxLayout()
        self.button_row.setSpacing(5)
        self.format_combo = QComboBox()
        self.format_combo.setMinimumWidth(120)
        self.format_combo.currentIndexChanged.connect(self._on_format_changed)
        self._combo_prev_idx = 0
        self.clip_btn = QPushButton("Clip…")
        self.clip_btn.clicked.connect(self._open_clip)
        self.schedule_btn = QPushButton("Schedule…")
        self.schedule_btn.setToolTip("Start this download at a later time")
        self.schedule_btn.clicked.connect(self._open_schedule)
        self.controls.addLayout(self.button_row)
        root.addLayout(self.controls)

        self.refresh(item)
        self._load_thumb(item.thumbnail)
        self._last_status = item.status

    # ── format combo ────────────────────────────────────────────────────────
    def _fill_format_combo(self) -> None:
        self.format_combo.blockSignals(True)
        self.format_combo.clear()
        self.format_combo.addItem(f"Default ({format_label(self.state.settings.format_preset, self.state.settings.custom_format)})")
        for k, label, _arg, _ext in FORMAT_PRESETS:
            self.format_combo.addItem(label)
        # v1.0.4: launch the format preview dialog
        self.format_combo.addItem("Show available formats…")
        # select current override if any
        if self.item.format_preset:
            for i, (k, _l, _a, _e) in enumerate(FORMAT_PRESETS, start=1):
                if k == self.item.format_preset:
                    self.format_combo.setCurrentIndex(i)
                    break
        else:
            self.format_combo.setCurrentIndex(0)
        self.format_combo.blockSignals(False)

    def _on_format_changed(self, idx: int) -> None:
        # "Show available formats…" is the last entry
        if idx == self.format_combo.count() - 1:
            # reset to previous selection, then open the dialog
            prev = self._combo_prev_idx or 0
            self.format_combo.blockSignals(True)
            self.format_combo.setCurrentIndex(prev)
            self.format_combo.blockSignals(False)
            self._open_formats()
            return
        self._combo_prev_idx = idx
        if idx <= 0:
            self.state.set_item_format(self.item.id, "", "")
        else:
            k, _l, _a, _e = FORMAT_PRESETS[idx - 1]
            self.state.set_item_format(self.item.id, k, "")

    def _open_formats(self) -> None:
        self.state.load_formats(self.item.id)
        dlg = FormatsDialog(self.state, self.item, self)
        dlg.exec()
        # refresh combo so a chosen custom format shows
        it = self.state.item(self.item.id)
        if it and it.status == "queued":
            self._fill_format_combo()

    def _open_schedule(self) -> None:
        dlg = ScheduleDialog(self.item, self)
        if dlg.exec() == QDialog.Accepted:
            self.state.set_item_schedule(self.item.id, dlg.value())
            it = self.state.item(self.item.id)
            if it:
                self.refresh(it)

    def _open_clip(self) -> None:
        dlg = ClipDialog(self.item, self)
        if dlg.exec() == QDialog.Accepted:
            s, e = dlg.values()
            self.state.set_item_clip(self.item.id, s, e)

    def _copy_url(self) -> None:
        """Copy the item's source URL to the system clipboard."""
        QGuiApplication.clipboard().setText(self.item.url)

    def _open_in_browser(self) -> None:
        """Open the item's source URL in the user's default browser."""
        QDesktopServices.openUrl(QUrl(self.item.url))

    # ── buttons ─────────────────────────────────────────────────────────────
    def _btn(self, text, tip, color, handler) -> QPushButton:
        b = QPushButton(text)
        b.setToolTip(tip)
        b.setFixedWidth(34)
        b.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; color: {color}; padding: 2px; }}"
            f"QPushButton:hover {{ background: #1d2230; }}"
        )
        b.clicked.connect(handler)
        return b

    def _rebuild_buttons(self) -> None:
        for i in reversed(range(self.button_row.count())):
            w = self.button_row.takeAt(i).widget()
            if w:
                w.deleteLater()
        st = self.item.status
        # per-item format + clip + schedule only while queued
        if st == "queued":
            if self.format_combo.parent() is None:
                self.button_row.addWidget(self.format_combo)
            self.button_row.addWidget(self.clip_btn)
            self.button_row.addWidget(self.schedule_btn)
        else:
            self.format_combo.setParent(None)
            self.clip_btn.setParent(None)
            self.schedule_btn.setParent(None)
        if st == "resolving":
            self.button_row.addWidget(self._btn("✕", "Remove", theme.ERR, lambda: self.state.remove(self.item.id)))
        elif st == "downloading":
            self.button_row.addWidget(self._btn("⏸", "Pause", theme.WARN, lambda: self.state.pause(self.item.id)))
            self.button_row.addWidget(self._btn("⏹", "Stop", theme.ERR, lambda: self.state.stop(self.item.id)))
            self.button_row.addWidget(self._btn("↻", "Retry", theme.TEXT, lambda: self.state.retry(self.item.id)))
        elif st == "paused":
            self.button_row.addWidget(self._btn("▶", "Resume", theme.OK, lambda: self.state.resume(self.item.id)))
            self.button_row.addWidget(self._btn("⏹", "Stop", theme.ERR, lambda: self.state.stop(self.item.id)))
            self.button_row.addWidget(self._btn("↻", "Retry", theme.TEXT, lambda: self.state.retry(self.item.id)))
        elif st == "queued":
            self.button_row.addWidget(self._btn("▶", "Start now", theme.OK, lambda: self.state.start_now(self.item.id)))
            # When a start is deferred (delay countdown) or scheduled, offer a
            # Stop to cancel it and park the item as stopped — otherwise only
            # Start now / Remove are available.
            if self.item.launch_at_ts > 0 or self.item.has_schedule:
                self.button_row.addWidget(self._btn("⏹", "Cancel scheduled start", theme.ERR, lambda: self.state.cancel_start(self.item.id)))
            self.button_row.addWidget(self._btn("✕", "Remove", theme.ERR, lambda: self.state.remove(self.item.id)))
        elif st in ("failed", "stopped"):
            self.button_row.addWidget(self._btn("↻", "Retry", theme.OK, lambda: self.state.retry(self.item.id)))
            if self.item.output_file_path:
                self.button_row.addWidget(self._btn("🗑", "Delete file", theme.ERR, lambda: self.state.delete_file(self.item.id)))
            else:
                self.button_row.addWidget(self._btn("✕", "Remove", theme.ERR, lambda: self.state.remove(self.item.id)))
        elif st == "done":
            self.button_row.addWidget(self._btn("📁", "Reveal", theme.ACCENT2, lambda: self.state.reveal(self.item.id)))
            self.button_row.addWidget(self._btn("🗑", "Delete file", theme.ERR, lambda: self.state.delete_file(self.item.id)))
            self.button_row.addWidget(self._btn("✕", "Remove", theme.MUTED, lambda: self.state.remove(self.item.id)))
        # Source-link actions — always available regardless of status.
        self.button_row.addWidget(self._btn("🔗", "Copy URL", theme.MUTED, self._copy_url))
        self.button_row.addWidget(self._btn("↗", "Open in browser", theme.MUTED, self._open_in_browser))

    # ── refresh from model ──────────────────────────────────────────────────
    def refresh(self, item: DownloadItem) -> None:
        self.item = item
        self.title.setText(item.display_title)

        meta_parts = [item.host]
        if item.uploader:
            meta_parts.append(item.uploader)
        if item.duration_str:
            meta_parts.append(item.duration_str)
        self.meta.setText("  ·  ".join(meta_parts))

        self.badge.setText(self._badge_text(item.status))
        self.badge.setStyleSheet(f"color: {self._badge_color(item.status)}; font-weight: 600; font-size: 11px;")
        self.fmt_chip.setText(item.format_desc)
        self.fmt_chip.setStyleSheet(
            f"background: {theme.LINE}; color: {theme.TEXT}; padding: 1px 6px; border-radius: 6px; font-size: 10px;"
            if item.format_desc else ""
        )
        if item.has_clip:
            s = item.clip_start or "0"
            e = item.clip_end or "end"
            self.clip_chip.setText(f"clip {s}→{e}")
            self.clip_chip.setStyleSheet(
                f"background: {theme.ACCENT}; color: #0e1014; padding: 1px 6px; border-radius: 6px; font-size: 10px;")
        else:
            self.clip_chip.setText("")
            self.clip_chip.setStyleSheet("")
        if item.has_schedule:
            try:
                dt = datetime.fromisoformat(item.start_at).strftime("%b %d, %H:%M")
            except Exception:
                dt = item.start_at
            self.schedule_chip.setText(f"starts {dt}")
            self.schedule_chip.setStyleSheet(
                f"background: {theme.ACCENT2}; color: #0e1014; padding: 1px 6px; border-radius: 6px; font-size: 10px;")
        else:
            self.schedule_chip.setText("")
            self.schedule_chip.setStyleSheet("")

        downloading = item.status in ("downloading", "paused")
        self.progress.setVisible(downloading and item.total_bytes > 0)
        self.percent.setVisible(downloading)
        self.spinner.setVisible(item.status == "downloading" and item.total_bytes == 0)
        # Countdown for a delay-deferred launch; the MainWindow tick timer
        # calls update_countdown() each ~250ms to keep the number live.
        self.countdown.setVisible(item.status == "queued" and item.launch_at_ts > 0)
        if item.status == "queued" and item.launch_at_ts > 0:
            self.update_countdown()
        # Auto-retry in flight: show which attempt this is so a re-queued
        # failed item reads as retrying, not mysteriously re-queued.
        if item.status == "queued" and item.retry_count > 0:
            mx = getattr(self.state.settings, "max_auto_retries", 3)
            self.retry_badge.setText(f"Auto-retry {item.retry_count}/{mx}")
            self.retry_badge.show()
        else:
            self.retry_badge.hide()
        if downloading:
            self.progress.setValue(int(item.progress * 1000))
            pct = int(item.progress * 100)
            self.percent.setText(f"paused · {pct}%" if item.status == "paused" else f"{pct}%")
        if item.status == "downloading" and item.total_bytes > 0:
            self.bytes_label.setText(f"{self._bytes(item.downloaded_bytes)} / {self._bytes(item.total_bytes)}"
                                     f"    {item.speed_str}    ETA {item.eta_str}")
        else:
            self.bytes_label.setText("")
        self.err_label.setText(item.error_message if item.status == "failed" else "")
        # Only rebuild the button row + format combo on a status transition,
        # not on every progress tick (which would flicker and thrash).
        if getattr(self, "_last_status", None) != item.status:
            self._rebuild_buttons()
            if item.status == "queued":
                self._fill_format_combo()
            self._last_status = item.status

    def update_countdown(self) -> None:
        """Recompute the 'Starting in Ns' label from the item's scheduled fire
        time. Called by MainWindow's tick timer while a deferred launch waits.
        Only touches the countdown label — the rest of the row is updated by
        refresh() on item_changed."""
        it = self.item
        if it is None or it.status != "queued" or it.launch_at_ts <= 0:
            self.countdown.hide()
            return
        import time
        remaining = it.launch_at_ts - time.time()
        if remaining > 0:
            self.countdown.setText(f"Starting in {max(1, int(remaining + 0.999))}s")
        else:
            self.countdown.setText("Starting…")
        self.countdown.show()

    @staticmethod
    def _bytes(n: int) -> str:
        for unit in ("B", "KB", "MB", "GB"):
            if abs(n) < 1024:
                return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
            n /= 1024.0
        return f"{n:.1f} TB"

    @staticmethod
    def _badge_text(st: str) -> str:
        return {"resolving": "Resolving", "queued": "Queued", "downloading": "Downloading",
                "paused": "Paused", "done": "Done", "failed": "Failed",
                "stopped": "Stopped"}.get(st, st)

    @staticmethod
    def _badge_color(st: str) -> str:
        return {"downloading": theme.ACCENT, "queued": theme.MUTED, "resolving": theme.MUTED,
                "paused": theme.WARN, "done": theme.OK, "failed": theme.ERR,
                "stopped": theme.MUTED}.get(st, theme.TEXT)

    # ── thumbnail ───────────────────────────────────────────────────────────
    def _load_thumb(self, url: str) -> None:
        if not url:
            return
        try:
            req = QNetworkRequest(QUrl(url))
            req.setAttribute(QNetworkRequest.RedirectPolicyAttribute,
                             QNetworkRequest.NoLessSafeRedirectPolicy)
            self._thumb_reply = self.nam.get(req)
            self._thumb_reply.finished.connect(self._on_thumb)
        except Exception:
            pass

    def _on_thumb(self) -> None:
        if not self._thumb_reply:
            return
        data = self._thumb_reply.readAll()
        pix = QPixmap()
        if pix.loadFromData(data):
            self.thumb.setPixmap(pix.scaled(132, 74, Qt.KeepAspectRatioByExpanding,
                                            Qt.SmoothTransformation))
        self._thumb_reply.deleteLater()
        self._thumb_reply = None


