"""Settings dialog (opened from File ▸ Settings…)."""
from __future__ import annotations

from PySide6.QtCore import Qt, QProcess
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QFormLayout, QHBoxLayout, QPushButton, QComboBox,
    QSpinBox, QDoubleSpinBox, QCheckBox, QLineEdit, QFileDialog, QGroupBox,
    QScrollArea, QWidget, QLabel, QMessageBox,
)

from ..models import (
    AppSettings, FORMAT_PRESETS, COOKIE_BROWSERS, CONVERT_FORMATS,
    TRANSCODE_VIDEO_CODECS, TRANSCODE_AUDIO_CODECS,
)
from ..backup import export_bundle, import_bundle
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

        # Optional video container conversion (mutually exclusive):
        # remux = fast container swap (no re-encode); transcode = full re-encode.
        self.remux = QCheckBox("Remux video to container (fast, no re-encode)")
        self.remux.setChecked(getattr(s, "remux_enabled", False))
        dl_layout.addRow(self.remux)
        self.transcode = QCheckBox("Transcode video to container (re-encode via ffmpeg)")
        self.transcode.setChecked(getattr(s, "transcode_enabled", False))
        dl_layout.addRow(self.transcode)
        self.convert_fmt = QComboBox()
        for f in CONVERT_FORMATS:
            self.convert_fmt.addItem(f, f)
        cur = getattr(s, "convert_format", "mp4") or "mp4"
        self.convert_fmt.setCurrentIndex(max(0, CONVERT_FORMATS.index(cur) if cur in CONVERT_FORMATS else 0))
        dl_layout.addRow("Container format", self.convert_fmt)
        # Codec pickers apply to transcode (re-encode) only — remux preserves
        # the source codecs, so they're disabled unless transcode is checked.
        self.t_vcodec = QComboBox()
        for k, label in TRANSCODE_VIDEO_CODECS:
            self.t_vcodec.addItem(label, k)
        vcur = getattr(s, "transcode_video_codec", "default") or "default"
        self.t_vcodec.setCurrentIndex(max(0, [k for k, _ in TRANSCODE_VIDEO_CODECS].index(vcur)
                                            if vcur in [k for k, _ in TRANSCODE_VIDEO_CODECS] else 0))
        dl_layout.addRow("Transcode video codec", self.t_vcodec)
        self.t_acodec = QComboBox()
        for k, label in TRANSCODE_AUDIO_CODECS:
            self.t_acodec.addItem(label, k)
        acur = getattr(s, "transcode_audio_codec", "default") or "default"
        self.t_acodec.setCurrentIndex(max(0, [k for k, _ in TRANSCODE_AUDIO_CODECS].index(acur)
                                            if acur in [k for k, _ in TRANSCODE_AUDIO_CODECS] else 0))
        dl_layout.addRow("Transcode audio codec", self.t_acodec)
        # Mutual exclusion: enabling one disables the other.
        self.remux.toggled.connect(self._on_remux_toggled)
        self.transcode.toggled.connect(self._on_transcode_toggled)
        self._update_convert_enabled()

        self.concurrent = QSpinBox()
        self.concurrent.setRange(1, 4)
        self.concurrent.setValue(s.max_concurrent)
        dl_layout.addRow("Concurrent downloads", self.concurrent)

        self.delay = QSpinBox()
        self.delay.setRange(0, 300)
        self.delay.setSuffix("s")
        self.delay.setSpecialValueText("Off")
        self.delay.setValue(getattr(s, "download_delay_seconds", 0))
        dl_layout.addRow("Delay between starts", self.delay)

        self.autoretry = QCheckBox("Auto-retry failed downloads")
        self.autoretry.setChecked(getattr(s, "auto_retry_failed", False))
        dl_layout.addRow(self.autoretry)
        self.maxretries = QSpinBox()
        self.maxretries.setRange(1, 10)
        self.maxretries.setValue(getattr(s, "max_auto_retries", 3))
        dl_layout.addRow("Max auto-retries", self.maxretries)
        self.autoretry.toggled.connect(self.maxretries.setEnabled)
        self.maxretries.setEnabled(self.autoretry.isChecked())

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

        # Backup / restore
        bk = QGroupBox("Backup")
        bk_layout = QFormLayout(bk)
        brow = QHBoxLayout()
        brow.setSpacing(8)
        exp = QPushButton("Export backup…")
        imp = QPushButton("Restore backup…")
        for b in (exp, imp):
            b.setStyleSheet(
                f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
                f" color: {theme.TEXT}; padding: 4px 12px; border-radius: 6px; }}"
                f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
        exp.clicked.connect(self._export_backup)
        imp.clicked.connect(self._import_backup)
        brow.addWidget(exp)
        brow.addWidget(imp)
        brow.addStretch(1)
        bk_layout.addRow("Local backup", brow)
        bk_hint = QLabel("Export your library, achievements, settings, and queue into one .json file. "
                         "Restore it on another machine to migrate without a cloud account. "
                         "Credentials aren't included.")
        bk_hint.setWordWrap(True)
        bk_hint.setStyleSheet(f"color: {theme.MUTED}; font-size: 10px;")
        bk_layout.addRow(bk_hint)
        form.addRow(bk)

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

    # ── backup / restore ─────────────────────────────────────────────────────
    def _appdata_dir(self) -> str:
        from ..app_state import _appdata_dir
        return _appdata_dir()

    def _export_backup(self) -> None:
        path, _ = QFileDialog.getSaveFileName(
            self, "Export backup", "TapeNexus-backup.json", "JSON (*.json)")
        if not path:
            return
        data = export_bundle(self._appdata_dir())
        if data is None:
            QMessageBox.warning(self, "Backup", "Couldn't build a backup from the current state.")
            return
        try:
            with open(path, "wb") as f:
                f.write(data)
            QMessageBox.information(self, "Backup",
                                    f"Exported backup to:\n{path}")
        except Exception:
            QMessageBox.warning(self, "Backup", "Couldn't write the backup file.")

    def _import_backup(self) -> None:
        if not self.state.can_restore_backup():
            QMessageBox.warning(
                self, "Restore", "Stop active downloads before restoring a backup.")
            return
        path, _ = QFileDialog.getOpenFileName(
            self, "Restore backup", "", "JSON (*.json)")
        if not path:
            return
        # The native picker yields the event loop, so a deferred launch may
        # have started while it was open. Recheck immediately before writing.
        if not self.state.can_restore_backup():
            QMessageBox.warning(
                self, "Restore", "Stop active downloads before restoring a backup.")
            return
        try:
            with open(path, "rb") as f:
                data = f.read()
            import_bundle(data, self._appdata_dir())
        except ValueError as e:
            QMessageBox.warning(self, "Restore", str(e))
            return
        except Exception:
            QMessageBox.warning(self, "Restore", "Couldn't read that backup file.")
            return
        # Pull restored files into the live managers so a later save can't
        # clobber them with pre-restore state before the restart.
        self.state.reload_restored_state()
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Question)
        box.setWindowTitle("Restore")
        box.setText("Your library, achievements, settings, and queue were restored. "
                    "Restart TapeNexus to load them.")
        now = box.addButton("Restart now", QMessageBox.AcceptRole)
        later = box.addButton("Later", QMessageBox.RejectRole)
        box.setDefaultButton(now)
        box.exec()
        if box.clickedButton() is now:
            import sys
            QProcess.startDetached(sys.executable, [])
            from PySide6.QtWidgets import QApplication
            QApplication.quit()
        else:
            # Prevent stale controls in this pre-restore dialog from later
            # saving over the settings that were just restored.
            self.accept()

    @staticmethod
    def _reveal(path: str) -> None:
        import os
        try:
            os.startfile(path)  # type: ignore[attr-defined]
        except Exception:
            pass

    def _update_convert_enabled(self) -> None:
        active = self.remux.isChecked() or self.transcode.isChecked()
        self.convert_fmt.setEnabled(active)
        tc = self.transcode.isChecked()
        self.t_vcodec.setEnabled(tc)
        self.t_acodec.setEnabled(tc)

    def _on_remux_toggled(self, on: bool) -> None:
        if on:
            self.transcode.setChecked(False)
        self._update_convert_enabled()

    def _on_transcode_toggled(self, on: bool) -> None:
        if on:
            self.remux.setChecked(False)
        self._update_convert_enabled()

    def _reset(self) -> None:
        d = AppSettings.default()
        self.dest.setText(d.destination_folder)
        self.format.setCurrentIndex(1)
        self.custom.setText(d.custom_format)
        self.concurrent.setValue(d.max_concurrent)
        self.delay.setValue(getattr(d, "download_delay_seconds", 0))
        self.autoretry.setChecked(getattr(d, "auto_retry_failed", False))
        self.maxretries.setValue(getattr(d, "max_auto_retries", 3))
        self.maxretries.setEnabled(self.autoretry.isChecked())
        self.remux.setChecked(getattr(d, "remux_enabled", False))
        self.transcode.setChecked(getattr(d, "transcode_enabled", False))
        cf = getattr(d, "convert_format", "mp4") or "mp4"
        self.convert_fmt.setCurrentIndex(max(0, CONVERT_FORMATS.index(cf) if cf in CONVERT_FORMATS else 0))
        vcur = getattr(d, "transcode_video_codec", "default") or "default"
        self.t_vcodec.setCurrentIndex(max(0, [k for k, _ in TRANSCODE_VIDEO_CODECS].index(vcur)
                                            if vcur in [k for k, _ in TRANSCODE_VIDEO_CODECS] else 0))
        acur = getattr(d, "transcode_audio_codec", "default") or "default"
        self.t_acodec.setCurrentIndex(max(0, [k for k, _ in TRANSCODE_AUDIO_CODECS].index(acur)
                                            if acur in [k for k, _ in TRANSCODE_AUDIO_CODECS] else 0))
        self._update_convert_enabled()
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
        s.auto_retry_failed = self.autoretry.isChecked()
        s.max_auto_retries = self.maxretries.value()
        s.remux_enabled = self.remux.isChecked()
        s.transcode_enabled = self.transcode.isChecked()
        s.convert_format = self.convert_fmt.currentData()
        s.transcode_video_codec = self.t_vcodec.currentData()
        s.transcode_audio_codec = self.t_acodec.currentData()
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
