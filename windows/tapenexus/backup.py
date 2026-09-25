"""One-click local backup/restore of TapeNexus state on Windows — for moving
between machines without a cloud account. Packs the four JSON state files in the
appdata directory (library, achievements, settings, queue) into one .json
bundle. Credentials (sync.local.json) are deliberately excluded so a shared
backup never leaks auth tokens."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import List, Optional

FILE_NAMES = ["library.json", "achievements.json", "settings.json", "queue.json"]
_BUNDLE_VERSION = 1


def export_bundle(appdata_dir: str) -> Optional[bytes]:
    """Build the backup bundle as pretty-printed JSON bytes. Missing files are
    recorded as null so a partial restore is still valid."""
    import os
    files = {}
    for name in FILE_NAMES:
        path = os.path.join(appdata_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                files[name] = json.load(f)
        except Exception:
            files[name] = None
    bundle = {
        "app": "TapeNexus",
        "version": _BUNDLE_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "files": files,
    }
    try:
        return json.dumps(bundle, indent=2, sort_keys=True).encode("utf-8")
    except Exception:
        return None


def import_bundle(data: bytes, appdata_dir: str) -> List[str]:
    """Write a backup bundle back into the appdata directory. Returns the list of
    files actually written (skips nulls). Raises ValueError on an unreadable
    bundle or an empty restore."""
    import os
    try:
        root = json.loads(data.decode("utf-8"))
    except Exception:
        raise ValueError("That file isn't a valid TapeNexus backup.")
    files = root.get("files") if isinstance(root, dict) else None
    if not isinstance(files, dict):
        raise ValueError("That file isn't a valid TapeNexus backup.")
    written: List[str] = []
    for name in FILE_NAMES:
        obj = files.get(name)
        if obj is None:
            continue
        path = os.path.join(appdata_dir, name)
        tmp = path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(obj, f, indent=2, sort_keys=True)
            os.replace(tmp, path)
            written.append(name)
        except Exception:
            pass
    if not written:
        raise ValueError("The backup didn't contain any restorable data.")
    return written