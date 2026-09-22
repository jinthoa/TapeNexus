"""Settings dialog (opened from File ▸ Settings…)."""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QFormLayout, QHBoxLayout, QPushButton, QComboBox,
    QSpinBox, QDoubleSpinBox, QCheckBox, QLineEdit, QFileDialog, QGroupBox,
    QGridLayout, QScrollArea, QWidget,
)

from ..models import AppSettings, FORMAT_PRESETS, COOKIE_BROWSERS
from . import theme


class SettingsDialog(QDialog):
    def __init__(self, state, parent=None) -> None:
        super().__init__(parent)
        self.state = state
        self.setWindowTitle("Tape Nexus — Settings")
        self.resize(560, 640)
        s = state.settings

        outer = QVBoxLayout(self)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        inner = QWidget()
        form = QFormLayout(inner)
        form.setSpacing(10)

        # Downloads
        dl = QGroupBox("Downloads")
        dl_layout = QFormLayout(dl)
        self.dest = QLineEdit(s.destination_folder)
        dest_row = QHBoxLayout()
        dest_row.addWidget(self.dest, 1)
        choose = QPushButton("Choose…")
        choose.clicked.connect(self._choose_folder)
        reveal = QPushButton("Reveal")
        reveal.clicked.connect(lambda: self._reveal(s.destination_folder))
        dest_row.addWidget(choose)
        dest_row.addWidget(reveal)
        dl_layout.addRow("Destination folder", dest_row)

        self.format = QComboBox()
        for k, label, _a, _e in FORMAT_PRESETS:
            self.format.addItem(label, k)
        self.format.setCurrentIndex(max(0, [k for k, *_ in FORMAT_PRESETS].index(s.format_preset)))
        dl_layout.addRow("Default format", self.format)
        self.custom = QLineEdit(s.custom_format)
        dl_layout.addRow("Custom -f string", self.custom)

        self.concurrent = QSpinBox()
        self.concurrent.setRange(1, 4)
        self.concurrent.setValue(s.max_concurrent)
        dl_layout.addRow("Concurrent downloads", self.concurrent)

        self.delay = QSpinBox()
        self.delay.setRange(0, 30)
        self.delay.setSuffix("s")
        self.delay.setSpecialValueText("Off")
        self.delay.setValue(getattr(s, "download_delay_seconds", 0))
        dl_layout.addRow("Delay between starts", self.delay)

        self.sponsor = QCheckBox("Remove sponsor segments (SponsorBlock)")
        self.sponsor.setChecked(s.sponsor_block)
        dl_layout.addRow(self.sponsor)
        self.meta = QCheckBox("Embed metadata")
        self.meta.setChecked(s.embed_metadata)
        dl_layout.addRow(self.meta)
        self.subs = QCheckBox("Embed subtitles")
        self.subs.setChecked(s.embed_subs)
        dl_layout.addRow(self.subs)
        self.sub_langs = QLineEdit(s.subtitle_langs)
        dl_layout.addRow("Subtitle languages", self.sub_langs)

        self.cookies = QComboBox()
        for k, label in COOKIE_BROWSERS:
            self.cookies.addItem(label, k)
        self.cookies.setCurrentIndex(max(0, [k for k, _ in COOKIE_BROWSERS].index(s.cookies_browser)))
        dl_layout.addRow("Cookies from browser", self.cookies)

        self.organize = QCheckBox("Organize downloads by site (YouTube/, Vimeo/, …)")
        self.organize.setChecked(s.organize_by_host)
        dl_layout.addRow(self.organize)

        self.expand = QCheckBox("Expand playlist links into one item per video")
        self.expand.setChecked(s.expand_playlists)
        dl_layout.addRow(self.expand)
        self.cap = QSpinBox()
        self.cap.setRange(1, 500)
        self.cap.setSingleStep(10)
        self.cap.setValue(s.playlist_cap)
        dl_layout.addRow("Playlist entry cap", self.cap)

        form.addRow(dl)

        # Clipboard
        cb = QGroupBox("Clipboard")
        cb_layout = QFormLayout(cb)
        self.autograb = QCheckBox("Auto-grab supported URLs from clipboard")
        self.autograb.setChecked(s.auto_grab_clipboard)
        cb_layout.addRow(self.autograb)
        self.autostart = QCheckBox("Start downloads automatically when a URL is detected")
        self.autostart.setChecked(s.auto_start_downloads)
        cb_layout.addRow(self.autostart)
        self.poll = QDoubleSpinBox()
        self.poll.setRange(0.5, 3.0)
        self.poll.setSingleStep(0.1)
        self.poll.setDecimals(1)
        self.poll.setValue(s.poll_interval_seconds)
        cb_layout.addRow("Poll interval (s)", self.poll)
        form.addRow(cb)

        # Notifications + quiet hours
        misc = QGroupBox("Notifications & scheduling")
        misc_layout = QFormLayout(misc)
        self.notify = QCheckBox("Notify when downloads finish or fail")
        self.notify.setChecked(s.notify_on_complete)
        misc_layout.addRow(self.notify)
        self.quiet = QCheckBox("Pause all downloads during a time window")
        self.quiet.setChecked(s.quiet_hours_enabled)
        misc_layout.addRow(self.quiet)
        self.quiet_start = QSpinBox(); self.quiet_start.setRange(0, 23); self.quiet_start.setValue(s.quiet_start)
        self.quiet_end = QSpinBox(); self.quiet_end.setRange(0, 23); self.quiet_end.setValue(s.quiet_end)
        misc_layout.addRow("From (hour)", self.quiet_start)
        misc_layout.addRow("To (hour)", self.quiet_end)
        form.addRow(misc)

        scroll.setWidget(inner)
        outer.addWidget(scroll, 1)

        # footer
        footer = QHBoxLayout()
        reset = QPushButton("Reset to defaults")
        reset.clicked.connect(self._reset)
        footer.addWidget(reset)
        footer.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        save = QPushButton("Save")
        save.setDefault(True)
        save.setStyleSheet(f"background: {theme.ACCENT}; color: #0e1014; padding: 6px 16px; border-radius: 6px;")
        save.clicked.connect(self._save)
        footer.addWidget(cancel)
        footer.addWidget(save)
        outer.addLayout(footer)

    def _choose_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(self, "Choose destination", self.dest.text() or "")
        if d:
            self.dest.setText(d)

    @staticmethod
    def _reveal(path: str) -> None:
        import os
        try:
            os.startfile(path)  # type: ignore[attr-defined]
        except Exception:
            pass

    def _reset(self) -> None:
        d = AppSettings.default()
        self.dest.setText(d.destination_folder)
        self.format.setCurrentIndex(1)
        self.custom.setText(d.custom_format)
        self.concurrent.setValue(d.max_concurrent)
        self.delay.setValue(getattr(d, "download_delay_seconds", 0))
        self.sponsor.setChecked(d.sponsor_block)
        self.meta.setChecked(d.embed_metadata)
        self.subs.setChecked(d.embed_subs)
        self.sub_langs.setText(d.subtitle_langs)
        self.cookies.setCurrentIndex(0)
        self.organize.setChecked(d.organize_by_host)
        self.expand.setChecked(d.expand_playlists)
        self.cap.setValue(d.playlist_cap)
        self.autograb.setChecked(d.auto_grab_clipboard)
        self.autostart.setChecked(d.auto_start_downloads)
        self.poll.setValue(d.poll_interval_seconds)
        self.notify.setChecked(d.notify_on_complete)
        self.quiet.setChecked(d.quiet_hours_enabled)
        self.quiet_start.setValue(d.quiet_start)
        self.quiet_end.setValue(d.quiet_end)

    def _save(self) -> None:
        s = self.state.settings
        s.destination_folder = self.dest.text()
        s.format_preset = self.format.currentData()
        s.custom_format = self.custom.text()
        s.max_concurrent = self.concurrent.value()
        s.download_delay_seconds = self.delay.value()
        s.sponsor_block = self.sponsor.isChecked()
        s.embed_metadata = self.meta.isChecked()
        s.embed_subs = self.subs.isChecked()
        s.subtitle_langs = self.sub_langs.text()
        s.cookies_browser = self.cookies.currentData()
        s.organize_by_host = self.organize.isChecked()
        s.expand_playlists = self.expand.isChecked()
        s.playlist_cap = self.cap.value()
        s.auto_grab_clipboard = self.autograb.isChecked()
        s.auto_start_downloads = self.autostart.isChecked()
        s.poll_interval_seconds = self.poll.value()
        s.notify_on_complete = self.notify.isChecked()
        s.quiet_hours_enabled = self.quiet.isChecked()
        s.quiet_start = self.quiet_start.value()
        s.quiet_end = self.quiet_end.value()
        self.state.update_settings(s)
        self.accept()