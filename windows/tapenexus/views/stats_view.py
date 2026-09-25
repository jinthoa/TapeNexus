"""Insights tab: a read-only dashboard built from the Library archive and the
achievements stats — downloads over time, top hosts, formats used, and the
cumulative totals already tracked for the leaderboard. Pure UI, no backend."""
from __future__ import annotations

from collections import Counter
from datetime import date, datetime, timedelta
from typing import List, Tuple

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QScrollArea, QFrame,
    QSizePolicy,
)

from . import theme


def _week_start(d: date) -> date:
    """Monday of the week containing d."""
    return d - timedelta(days=d.weekday())


def _fmt_bytes(n: int) -> str:
    if n <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    f = float(n)
    i = 0
    while f >= 1024 and i < len(units) - 1:
        f /= 1024.0
        i += 1
    return f"{int(f)} {units[i]}" if i <= 1 else f"{f:.1f} {units[i]}"


class _StatCard(QFrame):
    def __init__(self, icon: str, value: str, label: str, tint: str) -> None:
        super().__init__()
        self.setStyleSheet(
            f"QFrame {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
            f" border-radius: 12px; }}")
        v = QVBoxLayout(self)
        v.setContentsMargins(12, 12, 12, 12)
        v.setSpacing(6)
        ic = QLabel(icon)
        ic.setStyleSheet(f"font-size: 16px; color: {tint};")
        v.addWidget(ic)
        val = QLabel(value)
        val.setStyleSheet(f"font-size: 18px; font-weight: 700; color: {theme.TEXT};")
        v.addWidget(val)
        lbl = QLabel(label)
        lbl.setStyleSheet(f"font-size: 10px; color: {theme.MUTED};")
        v.addWidget(lbl)


class _HBar(QFrame):
    """One horizontal bar row: label | track+fill | count."""

    def __init__(self, label: str, count: int, max_count: int, tint: str) -> None:
        super().__init__()
        self.setStyleSheet("background: transparent;")
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(10)
        lbl = QLabel(label)
        lbl.setStyleSheet(f"font-size: 11px; font-weight: 500; color: {theme.TEXT};")
        lbl.setFixedWidth(170)
        row.addWidget(lbl)
        track = QFrame()
        track.setFixedHeight(12)
        track.setStyleSheet(f"background: {theme.PANEL2}; border-radius: 4px;")
        fill = QFrame(track)
        fill.setFixedHeight(12)
        frac = (count / max(max_count, 1)) if max_count > 0 else 0.0
        # Track width is unknown until laid out; use a fixed 260px track so the
        # fill width is deterministic without a resize event.
        track.setFixedWidth(260)
        fill.setFixedWidth(max(1, int(260 * frac)))
        fill.setStyleSheet(f"background: {tint}; border-radius: 4px;")
        row.addWidget(track)
        cnt = QLabel(str(count))
        cnt.setStyleSheet(f"font-size: 11px; font-weight: 600; color: {theme.MUTED};")
        cnt.setFixedWidth(34)
        cnt.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        row.addWidget(cnt)


def _section(title: str, hint: str = "") -> QFrame:
    card = QFrame()
    card.setStyleSheet(
        f"QFrame {{ background: {theme.PANEL}; border: 1px solid {theme.LINE};"
        f" border-radius: 12px; }}")
    v = QVBoxLayout(card)
    v.setContentsMargins(14, 14, 14, 14)
    v.setSpacing(10)
    head = QHBoxLayout()
    t = QLabel(title)
    t.setStyleSheet(f"font-size: 13px; font-weight: 600; color: {theme.TEXT};")
    head.addWidget(t)
    head.addStretch(1)
    if hint:
        h = QLabel(hint)
        h.setStyleSheet(f"font-size: 10px; color: {theme.MUTED};")
        head.addWidget(h)
    v.addLayout(head)
    return card, v


class StatsView(QWidget):
    def __init__(self, state) -> None:
        super().__init__()
        self.state = state

        outer = QVBoxLayout(self)
        outer.setContentsMargins(16, 12, 16, 12)
        outer.setSpacing(12)

        title = QLabel("Insights")
        title.setStyleSheet(f"font-size: 22px; font-weight: 700; color: {theme.TEXT};")
        outer.addWidget(title)
        sub = QLabel("Your download activity at a glance.")
        sub.setStyleSheet(f"font-size: 12px; color: {theme.MUTED};")
        outer.addWidget(sub)

        # Scrollable body so the dashboard never clips on small windows.
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setStyleSheet(
            f"QScrollArea {{ background: transparent; border: none; }}"
            f" QScrollBar:vertical {{ background: {theme.PANEL}; width: 8px; }}")
        body = QWidget()
        body.setStyleSheet("background: transparent;")
        self.body_layout = QVBoxLayout(body)
        self.body_layout.setContentsMargins(0, 0, 0, 0)
        self.body_layout.setSpacing(14)
        self.body_layout.addStretch(1)
        scroll.setWidget(body)
        outer.addWidget(scroll, 1)

        # Refresh whenever the library or achievements change.
        try:
            self.state.library.library_changed.connect(self._rebuild)
        except Exception:
            pass
        self._rebuild()

    # ── build / rebuild ──────────────────────────────────────────────────────
    def _clear(self) -> None:
        while self.body_layout.count() > 1:
            it = self.body_layout.takeAt(0)
            w = it.widget()
            if w is not None:
                w.deleteLater()

    def _rebuild(self) -> None:
        self._clear()
        stats = self.state.achievements.stats
        entries = list(self.state.library.entries)

        # Stat cards row.
        cards = QHBoxLayout()
        cards.setSpacing(10)
        cards.addWidget(_StatCard("⬇️", str(stats.total_completed), "Downloads", theme.ACCENT))
        cards.addWidget(_StatCard("💾", self.state.achievements.formatted_total_bytes(),
                                  "Total data", theme.ACCENT2))
        cards.addWidget(_StatCard("🔥", f"{stats.best_streak()}d", "Best streak", theme.WARN))
        cards.addWidget(_StatCard("🌍", str(len(stats.hosts_seen)), "Hosts", theme.BLUE))
        cards.addWidget(_StatCard("🏆", str(stats.score()), "Score", theme.OK))
        cards.addStretch(1)
        host = QWidget()
        host.setStyleSheet("background: transparent;")
        host.setLayout(cards)
        self._insert(host)

        self._insert(self._weekly_card(entries))
        self._insert(self._top_card("Top hosts", f"{len(stats.hosts_seen)} distinct",
                                    self._top_counts([e.host() for e in entries], 6),
                                    theme.ACCENT))
        self._insert(self._top_card("Formats used", "",
                                    self._top_counts(
                                        [e.format_desc or "unknown" for e in entries], 6),
                                    theme.ACCENT2))

    def _insert(self, w: QWidget) -> None:
        self.body_layout.insertWidget(self.body_layout.count() - 1, w)

    # ── charts ───────────────────────────────────────────────────────────────
    def _weekly_card(self, entries) -> QFrame:
        buckets = self._weekly_buckets(entries)
        max_count = max((b[1] for b in buckets), default=0) or 1
        card, v = _section("Downloads over the last 12 weeks",
                           hint=f"{len(entries)} archived")
        row = QHBoxLayout()
        row.setSpacing(6)
        for label, count in buckets:
            col = QVBoxLayout()
            col.setSpacing(4)
            col.setAlignment(Qt.AlignBottom)
            n = QLabel(str(count) if count > 0 else "")
            n.setStyleSheet(f"font-size: 9px; font-weight: 600; color: {theme.MUTED};")
            n.setAlignment(Qt.AlignCenter)
            col.addWidget(n)
            bar = QFrame()
            h = int(90 * count / max_count) if count > 0 else 0
            bar.setFixedHeight(max(3 if count > 0 else 0, h))
            bar.setFixedWidth(18)
            bar.setStyleSheet(
                f"background: {theme.ACCENT}; border-radius: 3px;")
            col.addWidget(bar)
            lb = QLabel(label)
            lb.setStyleSheet(f"font-size: 8px; color: {theme.MUTED};")
            lb.setAlignment(Qt.AlignCenter)
            col.addWidget(lb)
            wrap = QWidget()
            wrap.setStyleSheet("background: transparent;")
            wrap.setLayout(col)
            wrap.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
            row.addWidget(wrap)
        row.addStretch(1)
        v.addLayout(row)
        return card

    def _top_card(self, title: str, hint: str, rows: List[Tuple[str, int]],
                  tint: str) -> QFrame:
        card, v = _section(title, hint=hint)
        if not rows:
            empty = QLabel("Nothing archived yet — finish a download to see stats here.")
            empty.setStyleSheet(f"font-size: 11px; color: {theme.MUTED};")
            v.addWidget(empty)
        else:
            top = rows[0][1]
            for label, count in rows:
                v.addWidget(_HBar(label, count, top, tint))
        return card

    # ── data helpers ─────────────────────────────────────────────────────────
    def _weekly_buckets(self, entries) -> List[Tuple[str, int]]:
        today = date.today()
        starts = [_week_start(today - timedelta(weeks=i)) for i in range(11, -1, -1)]
        counts = {s: 0 for s in starts}
        for e in entries:
            try:
                d = datetime.fromisoformat(e.completed_at).date() if e.completed_at else None
            except Exception:
                d = None
            if d is None:
                continue
            ws = _week_start(d)
            if ws in counts:
                counts[ws] += 1
        out = []
        for s in starts:
            iso = s.isocalendar()
            out.append((f"{iso[1]}/{str(iso[0])[2:]}", counts[s]))
        return out

    def _top_counts(self, keys: List[str], limit: int) -> List[Tuple[str, int]]:
        c = Counter(keys)
        return c.most_common(limit)