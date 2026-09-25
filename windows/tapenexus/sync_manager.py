"""Optional cloud sync (Supabase): email + Google auth and an `achievements`
row per user so badges follow you across machines.

No Supabase SDK — we call the GoTrue Auth REST + PostgREST APIs directly with
urllib. The anon key is public by design; Row Level Security on the
`achievements` table is the real boundary. When sync.json is empty/absent, sync
is disabled and the app stays fully local — account is strictly opt-in.

Mirrors Sources/TapeNexus/SyncManager.swift on the macOS side.
"""
from __future__ import annotations

import base64
import ctypes
import hashlib
import http.server
import json
import os
import queue
import secrets
import shutil
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone
from typing import Optional

from PySide6.QtCore import QObject, Signal, Slot

from .achievements import AchievementStats

APP_NAME = "TapeNexus"
LOOPBACK_PORT = 47823


def _appdata_dir() -> str:
    base = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), APP_NAME)
    os.makedirs(base, exist_ok=True)
    return base


def _bundled_sync_path() -> Optional[str]:
    # PyInstaller onefile extracts to sys._MEIPASS; otherwise the package dir.
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass and os.path.exists(os.path.join(meipass, "sync.json")):
        return os.path.join(meipass, "sync.json")
    here = os.path.dirname(os.path.abspath(__file__))
    p = os.path.join(here, "sync.json")
    return p if os.path.exists(p) else None


def _resolve_config():
    """Return (url, anonKey) or (None, None) when sync isn't configured.
    Priority: env vars → writable %APPDATA%/TapeNexus/sync.json → bundled."""
    env_url = os.environ.get("TN_SUPABASE_URL")
    env_key = os.environ.get("TN_SUPABASE_ANON_KEY")
    if env_url and env_key:
        return env_url, env_key
    path = os.path.join(_appdata_dir(), "sync.json")
    if not os.path.exists(path):
        bundled = _bundled_sync_path()
        if bundled:
            try:
                shutil.copy(bundled, path)
            except Exception:
                pass
        else:
            try:
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump({"url": "", "anonKey": ""}, fh, indent=2)
            except Exception:
                pass
    try:
        with open(path, "r", encoding="utf-8") as fh:
            j = json.load(fh)
        u, k = (j.get("url") or "").strip(), (j.get("anonKey") or "").strip()
        if u and k:
            return u, k
    except Exception:
        pass
    return None, None


class SyncError(Exception):
    pass


class SyncManager(QObject):
    """Owns the Supabase session, persists it, and syncs achievements.
    Network calls run on worker threads; results surface via Qt signals."""

    # signed-in flag changed, signed-in email changed, auth attempt finished
    # (ok), auth error message.
    signed_in_changed = Signal(bool)
    email_changed = Signal(str)
    auth_done = Signal(bool)
    auth_error = Signal(str)
    # One-shot: emitted when the Credential Manager refused to store the session
    # and we fell back to the plaintext file, so the UI can warn the user.
    storage_warning = Signal(str)
    # Linked providers list changed (e.g. after a Google/email link). Lets the
    # avatar popup refresh its "Link …" buttons live.
    providers_changed = Signal(list)
    # Carries the remote stats (or None) from the worker thread back to the GUI
    # thread so the merge happens on the main thread.
    pull_ready = Signal(object)

    def __init__(self, support_dir: str) -> None:
        super().__init__()
        self._url, self._anon = _resolve_config()
        self._support_dir = support_dir
        self._session_path = os.path.join(support_dir, "sync_session.json")
        self._session = None  # dict: access_token, refresh_token, expires_at, user
        self._is_signed_in = False
        self._email = ""
        self._providers: list[str] = []
        self._storage_warned = False
        # Full-row upserts must stay ordered or an older request that finishes
        # last can roll cloud progress backwards.
        self._push_queue: queue.Queue = queue.Queue()
        threading.Thread(target=self._push_loop, daemon=True,
                         name="tn-achievement-push").start()
        self.is_configured = bool(self._url and self._anon)
        self.pull_ready.connect(self._on_pull_ready)
        if self.is_configured:
            self.restore_session()

    @property
    def is_signed_in(self) -> bool:
        return self._is_signed_in

    @property
    def email(self) -> str:
        return self._email

    @property
    def providers(self) -> list[str]:
        return list(self._providers)

    @property
    def user_id(self) -> Optional[str]:
        return self._uid()

    # ── HTTP helpers ───────────────────────────────────────────────────────
    def _headers(self, bearer: Optional[str] = None, json_body: bool = True) -> dict:
        h = {"apikey": self._anon}
        if json_body:
            h["Content-Type"] = "application/json"
        if bearer:
            h["Authorization"] = f"Bearer {bearer}"
        return h

    def _auth_post(self, path: str, body: dict, bearer: Optional[str] = None) -> dict:
        url = f"{self._url}/auth/v1/{path}"
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=self._headers(bearer), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as e:
            try:
                msg = json.loads(e.read().decode("utf-8")).get("msg") \
                      or json.loads(e.read().decode("utf-8")).get("message") \
                      or f"HTTP {e.code}"
            except Exception:
                msg = f"HTTP {e.code}"
            raise SyncError(msg)
        except Exception as e:
            raise SyncError(str(e))

    # ── session ────────────────────────────────────────────────────────────
    def _apply_session(self, j: dict) -> None:
        access = j.get("access_token")
        refresh = j.get("refresh_token")
        expires_in = j.get("expires_in")
        user = j.get("user") or {}
        uid = user.get("id")
        if not (access and refresh and expires_in and uid):
            if j.get("message"):
                raise SyncError(j["message"])
            raise SyncError("No session returned — if email confirmation is on, check your inbox.")
        expires_at = datetime.now(timezone.utc).timestamp() + float(expires_in)
        self._session = {
            "access_token": access,
            "refresh_token": refresh,
            "expires_at": expires_at,
            "user": {"id": uid, "email": user.get("email", ""),
                     "providers": _providers_from_user(user)},
        }
        self._save_session()
        self._set_signed_in(True, self._session["user"]["email"])
        self._set_providers(self._session["user"]["providers"])

    def _set_providers(self, providers: list[str]) -> None:
        if providers != self._providers:
            self._providers = list(providers)
            self.providers_changed.emit(self._providers)

    def _set_signed_in(self, on: bool, email: str = "") -> None:
        changed = self._is_signed_in != on
        self._is_signed_in = on
        self._email = email if on else ""
        if changed:
            self.signed_in_changed.emit(on)
            self.email_changed.emit(self._email)
        if not on and self._providers:
            self._set_providers([])

    def _save_session(self) -> None:
        if not self._session:
            self._clear_session()
            return
        # Try the Credential Manager first; on failure fall back to the
        # plaintext file + a one-shot warning so the app keeps working.
        if _cred_write(json.dumps(self._session)):
            return
        try:
            with open(self._session_path, "w", encoding="utf-8") as fh:
                json.dump(self._session, fh)
            if not self._storage_warned:
                self._storage_warned = True
                self.storage_warning.emit(
                    "Couldn't store your session in Windows Credential Manager "
                    "— falling back to an unencrypted file.")
        except Exception:
            pass

    def _clear_session(self) -> None:
        _cred_delete()
        try:
            os.remove(self._session_path)
        except OSError:
            pass

    def restore_session(self) -> None:
        # Prefer Credential Manager; fall back to the legacy plaintext file and
        # migrate it into the Credential Manager, then delete the file.
        blob = _cred_read()
        if blob is None:
            try:
                with open(self._session_path, "r", encoding="utf-8") as fh:
                    blob = fh.read()
                migrated = True
            except Exception:
                return
        else:
            migrated = False
        try:
            s = json.loads(blob)
        except Exception:
            return
        self._session = s
        if migrated:
            _cred_write(blob)
            try:
                os.remove(self._session_path)
            except OSError:
                pass
        now = datetime.now(timezone.utc).timestamp()
        if now > float(s.get("expires_at", 0)) - 60:
            threading.Thread(target=self._refresh, daemon=True).start()
        else:
            self._set_signed_in(True, s.get("user", {}).get("email", ""))
            self._set_providers(s.get("user", {}).get("providers", []))

    def _refresh(self) -> None:
        if not self._session:
            return
        try:
            j = self._auth_post("token?grant_type=refresh_token",
                                {"refresh_token": self._session["refresh_token"]})
            self._apply_session(j)
        except Exception:
            self._session = None
            self._clear_session()
            self._set_signed_in(False)

    # ── public auth (each spawns a worker thread) ──────────────────────────
    def sign_up(self, email: str, password: str) -> None:
        threading.Thread(target=self._do_auth, args=("signup", email, password), daemon=True).start()

    def sign_in(self, email: str, password: str) -> None:
        threading.Thread(target=self._do_auth, args=("token?grant_type=password", email, password), daemon=True).start()

    def sign_in_or_sign_up(self, email: str, password: str) -> None:
        """One-form auto-detect (like Google): try sign-in; on invalid
        credentials (maybe a new user) fall back to sign-up. If sign-up then
        reports the email is already registered, the password was wrong."""
        threading.Thread(target=self._do_auth_autodetect, args=(email, password), daemon=True).start()

    def _do_auth_autodetect(self, email: str, password: str) -> None:
        try:
            j = self._auth_post("token?grant_type=password",
                                {"email": email, "password": password})
            self._apply_session(j)
            self.auth_done.emit(True)
            return
        except SyncError as e:
            if "invalid" not in str(e).lower():
                self.auth_error.emit(str(e)); return
        except Exception as e:
            self.auth_error.emit(str(e)); return
        # Invalid credentials → maybe a brand-new user; try creating the account.
        try:
            j = self._auth_post("signup", {"email": email, "password": password})
            self._apply_session(j)
            self.auth_done.emit(True)
        except SyncError as e:
            if "already" in str(e).lower():
                self.auth_error.emit("Incorrect password for that email.")
            else:
                self.auth_error.emit(str(e))
        except Exception as e:
            self.auth_error.emit(str(e))

    def _do_auth(self, path: str, email: str, password: str) -> None:
        try:
            j = self._auth_post(path, {"email": email, "password": password})
            self._apply_session(j)
            self.auth_done.emit(True)
        except SyncError as e:
            self.auth_error.emit(str(e))
        except Exception as e:
            self.auth_error.emit(str(e))

    def sign_in_with_google(self) -> None:
        threading.Thread(target=self._do_google, daemon=True).start()

    def _do_google(self) -> None:
        try:
            verifier = _b64url(secrets.token_bytes(32))
            challenge = _b64url(hashlib.sha256(verifier.encode("utf-8")).digest())
            redirect = f"http://localhost:{LOOPBACK_PORT}/auth/callback"
            params = urllib.parse.urlencode({
                "provider": "google",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "redirect_to": redirect,
                "scopes": "email profile",
            })
            auth_url = f"{self._url}/auth/v1/authorize?{params}"
            code = _wait_for_callback(LOOPBACK_PORT, auth_url, timeout=180)
            if not code:
                raise SyncError("Google sign-in timed out or was cancelled.")
            j = self._auth_post("token?grant_type=pkce",
                                {"auth_code": code, "code_verifier": verifier})
            self._apply_session(j)
            self.auth_done.emit(True)
        except SyncError as e:
            self.auth_error.emit(str(e))
        except Exception as e:
            self.auth_error.emit(str(e))

    def sign_out(self) -> None:
        if not self._session:
            return

        def _do() -> None:
            try:
                self._auth_post("logout", {}, bearer=self._session["access_token"])
            except Exception:
                pass
            self._session = None
            self._clear_session()
            self._set_signed_in(False)

        threading.Thread(target=_do, daemon=True).start()

    # ── identity linking ──────────────────────────────────────────────────
    def link_google(self) -> None:
        """Link Google onto the current account (both identities → one
        user_id → shared achievements row). Worker-threaded."""
        threading.Thread(target=self._do_link_google, daemon=True).start()

    def _do_link_google(self) -> None:
        try:
            if not self._session:
                raise SyncError("Not signed in.")
            verifier = _b64url(secrets.token_bytes(32))
            challenge = _b64url(hashlib.sha256(verifier.encode("utf-8")).digest())
            redirect = f"http://localhost:{LOOPBACK_PORT}/auth/callback"
            params = urllib.parse.urlencode({
                "provider": "google",
                "scopes": "email profile",
                "redirect_to": redirect,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            })
            link_url = f"{self._url}/auth/v1/user/identities/authorize?{params}"
            # The endpoint needs the bearer token, so fetch it ourselves and
            # stop at the 302 to grab Google's consent URL (no secret in it).
            google_url = _capture_redirect(
                link_url, self._headers(self._session["access_token"]))
            if not google_url:
                raise SyncError("Could not start Google linking.")
            code = _wait_for_callback(LOOPBACK_PORT, google_url, timeout=180)
            if not code:
                raise SyncError("Google linking timed out or was cancelled.")
            j = self._auth_post("token?grant_type=pkce",
                                {"auth_code": code, "code_verifier": verifier})
            self._apply_session(j)
            self._refresh_user()
            self.auth_done.emit(True)
        except SyncError as e:
            self.auth_error.emit(str(e))
        except Exception as e:
            self.auth_error.emit(str(e))

    def set_password(self, password: str) -> None:
        """Set a password on a Google-only account so email+password also
        works. Worker-threaded; surfaces via auth_done/auth_error."""
        threading.Thread(target=self._do_set_password, args=(password,), daemon=True).start()

    def _do_set_password(self, password: str) -> None:
        try:
            if not self._session:
                raise SyncError("Not signed in.")
            self._auth_request("PUT", "user", {"password": password},
                               bearer=self._session["access_token"])
            self._refresh_user()
            self.auth_done.emit(True)
        except SyncError as e:
            self.auth_error.emit(str(e))
        except Exception as e:
            self.auth_error.emit(str(e))

    def _refresh_user(self) -> None:
        """Re-fetch the user so `providers` reflects a just-linked identity."""
        if not self._session:
            return
        try:
            user = self._auth_request("GET", "user", None,
                                      bearer=self._session["access_token"])
            if user and isinstance(user, dict):
                provs = _providers_from_user(user)
                if self._session.get("user"):
                    self._session["user"]["providers"] = provs
                    self._session["user"]["email"] = user.get("email",
                        self._session["user"].get("email", ""))
                self._save_session()
                self._set_providers(provs)
                if user.get("email"):
                    self._email = user["email"]
                    self.email_changed.emit(self._email)
        except Exception:
            pass

    def _auth_request(self, method: str, path: str, body, bearer: str = None) -> dict:
        url = f"{self._url}/auth/v1/{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, headers=self._headers(bearer), method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as e:
            try:
                msg = json.loads(e.read().decode("utf-8")).get("msg") \
                      or json.loads(e.read().decode("utf-8")).get("message") \
                      or f"HTTP {e.code}"
            except Exception:
                msg = f"HTTP {e.code}"
            raise SyncError(msg)
        except Exception as e:
            raise SyncError(str(e))

    # ── achievements sync ──────────────────────────────────────────────────
    def _bearer(self) -> Optional[str]:
        return self._session["access_token"] if self._session else None

    def _uid(self) -> Optional[str]:
        return self._session["user"]["id"] if self._session else None

    def push_achievements(self, stats: AchievementStats) -> None:
        """Fire-and-forget upsert of the local stats to this user's row."""
        if not self._is_signed_in:
            return
        row = self._row_from_stats(stats)
        token = self._bearer()
        self._push_queue.put((row, token))

    def _push_loop(self) -> None:
        while True:
            row, token = self._push_queue.get()
            try:
                self._do_push(row, token)
            finally:
                self._push_queue.task_done()

    def _do_push(self, row: dict, token) -> None:
        try:
            url = f"{self._url}/rest/v1/achievements?on_conflict=user_id"
            data = json.dumps(row).encode("utf-8")
            headers = self._headers(token)
            headers["Prefer"] = "return=representation,resolution=merge-duplicates"
            req = urllib.request.Request(url, data=data, headers=headers, method="POST")
            urllib.request.urlopen(req, timeout=30).close()
        except Exception:
            pass

    def pull_and_merge(self, achievements_manager) -> None:
        """Pull the server row + merge into local (on the GUI thread via a
        signal), then push the merged snapshot back."""
        if not self._is_signed_in:
            return
        requested_uid = self._uid()
        token = self._bearer()
        threading.Thread(target=self._do_pull,
                         args=(requested_uid, token, achievements_manager),
                         daemon=True).start()

    def _do_pull(self, requested_uid, token, target) -> None:
        try:
            url = f"{self._url}/rest/v1/achievements?select=*&limit=1"
            req = urllib.request.Request(url, headers=self._headers(token), method="GET")
            with urllib.request.urlopen(req, timeout=30) as r:
                rows = json.loads(r.read().decode("utf-8") or "[]")
            remote = self._stats_from_row(rows[0]) if rows else None
            # Emit to marshal the merge onto the GUI thread (queued connection).
            self.pull_ready.emit((requested_uid, target, remote))
        except Exception:
            pass

    @Slot(object)
    def _on_pull_ready(self, payload) -> None:
        if not isinstance(payload, tuple) or len(payload) != 3:
            return
        requested_uid, target, remote = payload
        if not requested_uid or self._uid() != requested_uid:
            return
        if remote is not None:
            target.merge(remote)
        self.push_achievements(target.stats)

    # ── row <-> stats ──────────────────────────────────────────────────────
    def _row_from_stats(self, s: AchievementStats) -> dict:
        row = {
            "user_id": self._uid(),
            "total_completed": s.total_completed,
            "total_bytes": s.total_bytes,
            "unlocked_ids": sorted(s.unlocked_ids),
            "night_owl": s.night_owl,
            "early_bird": s.early_bird,
            "hosts_seen": sorted(s.hosts_seen),
            "presets_used": sorted(s.presets_used),
            "completion_days": sorted(s.completion_days),
            "did_clip": s.did_clip,
            "did_schedule": s.did_schedule,
            "playlists_expanded": s.playlists_expanded,
            "did_retry_recover": s.did_retry_recover,
            "weekend_warrior": s.weekend_warrior,
            "score": s.score,
            "display_name": s.display_name,
            "leaderboard_opt_in": s.leaderboard_opt_in,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        if s.first_completed_at:
            row["first_completed_at"] = s.first_completed_at
        if s.leaderboard_settings_at:
            row["leaderboard_settings_at"] = s.leaderboard_settings_at
        return row

    @staticmethod
    def _stats_from_row(row: dict) -> AchievementStats:
        s = AchievementStats()
        s.total_completed = int(row.get("total_completed") or 0)
        s.total_bytes = int(row.get("total_bytes") or 0)
        ids = row.get("unlocked_ids")
        if isinstance(ids, list):
            s.unlocked_ids = set(ids)
        elif isinstance(ids, str):
            try:
                s.unlocked_ids = set(json.loads(ids))
            except Exception:
                s.unlocked_ids = set()
        s.night_owl = bool(row.get("night_owl"))
        s.early_bird = bool(row.get("early_bird"))
        s.first_completed_at = row.get("first_completed_at")
        for key, attr in (("hosts_seen", "hosts_seen"),
                          ("presets_used", "presets_used"),
                          ("completion_days", "completion_days")):
            val = row.get(key)
            if isinstance(val, list):
                setattr(s, attr, set(val))
        s.did_clip = bool(row.get("did_clip"))
        s.did_schedule = bool(row.get("did_schedule"))
        s.playlists_expanded = int(row.get("playlists_expanded") or 0)
        s.did_retry_recover = bool(row.get("did_retry_recover"))
        s.weekend_warrior = bool(row.get("weekend_warrior"))
        s.display_name = str(row.get("display_name") or "")
        s.leaderboard_opt_in = bool(row.get("leaderboard_opt_in"))
        s.leaderboard_settings_at = row.get("leaderboard_settings_at")
        return s

    # ── leaderboard ─────────────────────────────────────────────────────────
    def fetch_leaderboard(self) -> list:
        """Synchronous top-100 leaderboard fetch. Call from a worker thread;
        returns a list of dicts {user_id, display_name, score, total_completed}.
        """
        if not self._is_signed_in:
            return []
        try:
            url = (f"{self._url}/rest/v1/leaderboard"
                   f"?select=user_id,display_name,score,total_completed"
                   f"&order=score.desc,total_completed.desc&limit=100")
            req = urllib.request.Request(url, headers=self._headers(self._bearer()),
                                         method="GET")
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8") or "[]")
        except Exception:
            return []

    def fetch_my_rank(self, my_score: int) -> Optional[int]:
        """Synchronous exact rank (1-based) = count of opted-in players with a
        strictly higher score + 1. Call from a worker thread."""
        if not self._is_signed_in:
            return None
        try:
            url = (f"{self._url}/rest/v1/leaderboard"
                   f"?select=user_id&score=gt.{int(my_score)}")
            headers = self._headers(self._bearer(), json_body=False)
            headers["Prefer"] = "count=exact"
            headers["Range"] = "0-0"
            req = urllib.request.Request(url, headers=headers, method="GET")
            with urllib.request.urlopen(req, timeout=30) as r:
                # Content-Range looks like "0-0/42" (or "0-0/*" when empty).
                range_header = r.headers.get("Content-Range", "")
            total = range_header.split("/")[-1] if "/" in range_header else ""
            if total == "*":
                return 1
            n = int(total)
            return n + 1
        except Exception:
            return None

    def fetch_near_me(self, my_score: int):
        """Synchronous near-me fetch. Returns (above, me_and_below) lists of
        leaderboard dicts. `above` = up to 4 players with a higher score, closest
        first (score asc); `me_and_below` = me + up to 4 below (score desc), so
        the caller can render a window of 9 around the user. Call from a worker
        thread."""
        empty = ([], [])
        if not self._is_signed_in:
            return empty
        score = int(my_score)
        try:
            above_url = (
                f"{self._url}/rest/v1/leaderboard"
                f"?select=user_id,display_name,score,total_completed"
                f"&score=gt.{score}&order=score.asc,total_completed.asc&limit=4")
            req = urllib.request.Request(above_url, headers=self._headers(self._bearer()),
                                         method="GET")
            with urllib.request.urlopen(req, timeout=30) as r:
                above = json.loads(r.read().decode("utf-8") or "[]")
            below_url = (
                f"{self._url}/rest/v1/leaderboard"
                f"?select=user_id,display_name,score,total_completed"
                f"&score=lte.{score}&order=score.desc,total_completed.desc&limit=5")
            req = urllib.request.Request(below_url, headers=self._headers(self._bearer()),
                                         method="GET")
            with urllib.request.urlopen(req, timeout=30) as r:
                below = json.loads(r.read().decode("utf-8") or "[]")
            return above, below
        except Exception:
            return empty


# ── PKCE + loopback helpers ─────────────────────────────────────────────────

def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("utf-8")


# ── Windows Credential Manager (dependency-free ctypes) ─────────────────────
# Stores the Supabase session blob as a generic credential (target
# `TapeNexus\session`) so access/refresh tokens aren't sitting in a plaintext
# file. No pip dependency — advapi32 ships on every Windows install. On non
# Windows (e.g. importing this module on macOS for py_compile) the calls are
# no-ops that report failure so the caller falls back to the file.

_CRED_TARGET = "TapeNexus\\session"
_CRED_TYPE_GENERIC = 1
_CRED_PERSIST_LOCAL_MACHINE = 2


def _cred_bindings():
    """Return (advapi32, CredWriteW, CredReadW, CredDeleteW) or None off-Windows."""
    if os.name != "nt":
        return None
    try:
        advapi32 = ctypes.WinDLL("advapi32")
        advapi32.CredWriteW.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        advapi32.CredWriteW.restype = ctypes.c_int
        advapi32.CredReadW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
        advapi32.CredReadW.restype = ctypes.c_int
        advapi32.CredDeleteW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
        advapi32.CredDeleteW.restype = ctypes.c_int
        return advapi32
    except Exception:
        return None


class _CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Flags", ctypes.c_uint32),
        ("Type", ctypes.c_uint32),
        ("TargetName", ctypes.c_wchar_p),
        ("Comment", ctypes.c_wchar_p),
        ("LastWritten", ctypes.c_uint64),
        ("CredentialBlobSize", ctypes.c_uint32),
        ("CredentialBlob", ctypes.c_void_p),
        ("Persist", ctypes.c_uint32),
        ("AttributeCount", ctypes.c_uint32),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", ctypes.c_wchar_p),
        ("UserName", ctypes.c_wchar_p),
    ]


def _cred_write(blob: str) -> bool:
    adv = _cred_bindings()
    if not adv:
        return False
    data = blob.encode("utf-16-le")
    buf = ctypes.create_string_buffer(data, len(data))
    c = _CREDENTIAL()
    ctypes.memset(ctypes.byref(c), 0, ctypes.sizeof(c))
    c.Type = _CRED_TYPE_GENERIC
    c.TargetName = _CRED_TARGET
    c.CredentialBlobSize = len(data)
    c.CredentialBlob = ctypes.cast(buf, ctypes.c_void_p)
    c.Persist = _CRED_PERSIST_LOCAL_MACHINE
    c.UserName = "TapeNexus"
    ok = adv.CredWriteW(ctypes.byref(c), 0) != 0
    return ok


def _cred_read() -> Optional[str]:
    adv = _cred_bindings()
    if not adv:
        return None
    ptr = ctypes.c_void_p()
    if adv.CredReadW(_CRED_TARGET, _CRED_TYPE_GENERIC, 0, ctypes.byref(ptr)) == 0:
        return None
    try:
        c = ctypes.cast(ptr, ctypes.POINTER(_CREDENTIAL)).contents
        size = c.CredentialBlobSize
        if size == 0:
            return None
        raw = (ctypes.c_char * size).from_address(c.CredentialBlob)
        return bytes(raw).decode("utf-16-le")
    finally:
        ctypes.windll.advapi32.CredFree(ptr)


def _cred_delete() -> None:
    adv = _cred_bindings()
    if not adv:
        return
    adv.CredDeleteW(_CRED_TARGET, _CRED_TYPE_GENERIC, 0)


def _providers_from_user(user: dict) -> list[str]:
    """Linked provider names from a GoTrue user object (identities first,
    then app_metadata fallback)."""
    out: list[str] = []
    for ident in (user.get("identities") or []):
        if isinstance(ident, dict) and ident.get("provider"):
            out.append(ident["provider"])
    if not out:
        am = user.get("app_metadata") or {}
        if am.get("provider"):
            out = [am["provider"]]
        elif am.get("providers"):
            out = list(am["providers"])
    return out


class _RedirectHeld(Exception):
    """Raised by the no-redirect handler to surface a 3xx Location."""
    def __init__(self, location: str) -> None:
        super().__init__(location)
        self.location = location


class _StopRedirect(urllib.request.HTTPRedirectHandler):
    """Stops urllib from following a 3xx, surfacing the Location instead."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise _RedirectHeld(newurl)


def _capture_redirect(url: str, headers: dict) -> Optional[str]:
    """GETs `url` and returns the Location of the first 3xx without following
    it (the bearer header must not be carried into the browser)."""
    opener = urllib.request.build_opener(_StopRedirect)
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        opener.open(req, timeout=30).close()
        return None
    except _RedirectHeld as r:
        return r.location
    except Exception:
        return None


class _CBHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        code = (q.get("code") or [None])[0]
        self.server.result_code = code  # type: ignore[attr-defined]
        body = b"<h2>Signed in - you can close this tab.</h2>" if code \
            else b"<h2>Sign-in cancelled.</h2>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a) -> None:  # silence
        pass


def _wait_for_callback(port: int, auth_url: str, timeout: float) -> Optional[str]:
    server = http.server.HTTPServer(("127.0.0.1", port), _CBHandler)
    server.result_code = None  # type: ignore[attr-defined]
    server.timeout = timeout
    threading.Thread(target=server.handle_request, daemon=True).start()
    webbrowser.open(auth_url)
    # Block until the single request is handled (handle_request honors timeout).
    deadline = datetime.now(timezone.utc).timestamp() + timeout
    while server.result_code is None and datetime.now(timezone.utc).timestamp() < deadline:
        threading.Event().wait(0.25)
    server.server_close()
    return server.result_code  # type: ignore[return-value]
