"""Subscriptions tab: paste a channel/playlist URL, pick a format preset and a
check interval; the app polls for new entries on that cadence and auto-queues
them. Each row shows the last-checked time and how many new videos were found
on the last pass, with a manual Check-now button."""
from __future__ import annotations

import uuid
from datetime import datetime

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QLineEdit, QComboBox, QSpinBox,
    QPushButton, QScrollArea, QSizePolicy, QFrame, QCheckBox,
)

from . import theme
from ..models import FORMAT_PRESETS, format_label
from ..subscription_manager import Subscription


def _rel_time(iso: str) -> str:
    if not iso:
        return ""
    try:
        last = datetime.fromisoformat(iso)
        secs = (datetime.now() - last).total_seconds()
    except Exception:
        return ""
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{int(secs // 60)}m ago"
    if secs < 86400:
        return f"{int(secs // 3600)}h ago"
    return f"{int(secs // 86400)}d ago"


class SubscriptionRow(QFrame):
    def __init__(self, state, sub: Subscription) -> None:
        super().__init__()
        self.state = state
        self.sub = sub
        self.setObjectName("subrow")
        self.setStyleSheet(
            f"QFrame#subrow {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 10px; }}")
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

        root = QHBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(14)

        center = QVBoxLayout()
        center.setSpacing(6)
        title = QLabel(sub.display_title)
        title.setStyleSheet(f"font-weight: 600; font-size: 13px; color: {theme.TEXT};")
        title.setWordWrap(False)
        center.addWidget(title)
        preset_lbl = format_label(sub.preset, "")
        meta = QLabel("  ·  ".join([
            sub.host, preset_lbl, f"every {sub.interval_minutes}m",
            (_rel_time(sub.last_checked_at) and f"checked {_rel_time(sub.last_checked_at)}") or "",
        ]))
        meta.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        center.addWidget(meta)
        if sub.last_new_count > 0:
            st = QLabel(f"{sub.last_new_count} new video{'s' if sub.last_new_count != 1 else ''} queued last check")
            st.setStyleSheet(f"color: {theme.OK}; font-size: 11px;")
        elif sub.last_checked_at:
            st = QLabel("Up to date")
            st.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        else:
            st = QLabel("Baseline pending…")
            st.setStyleSheet(f"color: {theme.MUTED}; font-size: 11px;")
        center.addWidget(st)
        root.addLayout(center, 1)

        actions = QHBoxLayout()
        actions.setSpacing(6)
        self.enabled = QCheckBox()
        self.enabled.setChecked(sub.enabled)
        self.enabled.setStyleSheet(f"QCheckBox {{ background: transparent; }}")
        self.enabled.toggled.connect(
            lambda on: self.state.subscriptions.update(sub.id, enabled=on))
        actions.addWidget(self.enabled)
        chk = QPushButton("↻")
        chk.setToolTip("Check now")
        chk.setFixedWidth(34)
        chk.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; color: {theme.ACCENT2}; }}"
            f"QPushButton:hover {{ background: #1d2230; }}")
        chk.clicked.connect(lambda: self.state.check_subscription(sub.id))
        actions.addWidget(chk)
        rm = QPushButton("✕")
        rm.setToolTip("Remove")
        rm.setFixedWidth(34)
        rm.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 6px; color: {theme.MUTED}; }}"
            f"QPushButton:hover {{ background: #1d2230; }}")
        rm.clicked.connect(lambda: self.state.subscriptions.remove(sub.id))
        actions.addWidget(rm)
        root.addLayout(actions)


class SubscriptionsView(QWidget):
    def __init__(self, state) -> None:
        super().__init__()
        self.state = state
        self._rows = {}

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 12, 16, 12)
        root.setSpacing(10)

        bar = QHBoxLayout()
        bar.setSpacing(10)
        title = QLabel("📡  Subscriptions")
        title.setStyleSheet(f"font-size: 15px; font-weight: 600; color: {theme.TEXT};")
        bar.addWidget(title)
        bar.addStretch(1)
        check_all = QPushButton("Check all")
        check_all.setCursor(Qt.PointingHandCursor)
        check_all.setStyleSheet(
            f"QPushButton {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" color: {theme.TEXT}; padding: 4px 12px; border-radius: 6px; }}"
            f"QPushButton:hover {{ border: 1px solid {theme.ACCENT}; }}")
        check_all.clicked.connect(self.state.check_all_subscriptions)
        bar.addWidget(check_all)
        root.addLayout(bar)

        # Add bar
        addbar = QHBoxLayout()
        addbar.setSpacing(8)
        self.url_edit = QLineEdit()
        self.url_edit.setPlaceholderText("Paste a channel or playlist URL…")
        self.url_edit.returnPressed.connect(self._add)
        addbar.addWidget(self.url_edit, 1)
        self.preset = QComboBox()
        for k, label, _arg, _ext in FORMAT_PRESETS:
            self.preset.addItem(label, k)
        self.preset.setCurrentIndex(0)
        self.preset.setFixedWidth(150)
        addbar.addWidget(self.preset)
        self.interval = QSpinBox()
        self.interval.setRange(15, 1440)
        self.interval.setSingleStep(15)
        self.interval.setValue(360)
        self.interval.setSuffix("m")
        self.interval.setFixedWidth(95)
        addbar.addWidget(self.interval)
        add_btn = QPushButton("Add")
        add_btn.setCursor(Qt.PointingHandCursor)
        add_btn.setStyleSheet(
            f"QPushButton {{ background: {theme.ACCENT}; color: #0e1014; padding: 5px 14px;"
            f" border-radius: 6px; font-weight: 600; }}"
            f"QPushButton:disabled {{ background: {theme.PANEL}; color: {theme.MUTED}; }}")
        add_btn.clicked.connect(self._add)
        addbar.addWidget(add_btn)
        root.addLayout(addbar)

        # scrollable list
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(f"QScrollArea {{ border: none; background: {theme.BG}; }}")
        self.host = QWidget()
        self.host.setStyleSheet("background: transparent;")
        self.list_layout = QVBoxLayout(self.host)
        self.list_layout.setContentsMargins(0, 0, 0, 0)
        self.list_layout.setSpacing(8)
        self.list_layout.addStretch(1)
        self.scroll.setWidget(self.host)
        root.addWidget(self.scroll, 1)

        self.empty = QLabel("Paste a channel or playlist URL above and TapeNexus will "
                            "auto-queue new videos for you.")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setStyleSheet(f"color: {theme.MUTED}; font-size: 13px;")
        self.empty.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        root.addWidget(self.empty)

        state.subscriptions.subs_changed.connect(self._rebuild)
        self._rebuild()

    def _add(self) -> None:
        u = self.url_edit.text().strip()
        if not u:
            return
        sub = Subscription(id=str(uuid.uuid4()), url=u, preset=self.preset.currentData(),
                           interval_minutes=self.interval.value(), enabled=True)
        self.state.subscriptions.add(sub)
        self.url_edit.clear()
        # Baseline immediately so its current entries are recorded without
        # queuing the back catalogue.
        self.state.check_subscription(sub.id)

    def _rebuild(self) -> None:
        for w in list(self._rows.values()):
            self.list_layout.removeWidget(w)
            w.deleteLater()
        self._rows.clear()
        subs = self.state.subscriptions.subs
        for s in subs:
            row = SubscriptionRow(self.state, s)
            self._rows[s.id] = row
            self.list_layout.insertWidget(self.list_layout.count() - 1, row)
        self.empty.setVisible(not subs)