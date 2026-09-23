"""Tape Nexus — Windows port (PySide6).

Runtime version constant. Kept in sync with build.py's VERSION / the GitHub
release tag; the frozen .exe reads this at runtime for the app self-update
check. (build.py itself uses the TN_VERSION env var set by CI, but the
*running* app has no build-time env, so this is the source of truth at runtime.)
"""
__version__ = "1.0.11"