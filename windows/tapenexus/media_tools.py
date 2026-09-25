"""Post-download tools that run the bundled ffmpeg.exe on a Library file:
extract audio, transcode to MP4, and trim a clip. ffmpeg is the same binary
yt-dlp uses for merging, so no new dependency is shipped."""
from __future__ import annotations

import os
from typing import List, Tuple


def _output_url(inp: str, suffix: str, ext: str) -> str:
    """A non-clobbering output path beside the input: <name><suffix>.<ext>."""
    d = os.path.dirname(inp)
    base = os.path.splitext(os.path.basename(inp))[0]
    candidate = os.path.join(d, f"{base}{suffix}.{ext}")
    i = 2
    while os.path.exists(candidate):
        candidate = os.path.join(d, f"{base}{suffix}-{i}.{ext}")
        i += 1
    return candidate


def extract_audio_mp3(inp: str) -> Tuple[List[str], str]:
    out = _output_url(inp, "-audio", "mp3")
    return (["-i", inp, "-vn", "-c:a", "libmp3lame", "-q:a", "2", out], out)


def extract_audio_aac(inp: str) -> Tuple[List[str], str]:
    out = _output_url(inp, "-audio", "m4a")
    return (["-i", inp, "-vn", "-c:a", "aac", "-b:a", "192k", out], out)


def transcode_mp4(inp: str) -> Tuple[List[str], str]:
    out = _output_url(inp, "-mp4", "mp4")
    return (["-i", inp, "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", out], out)


def trim(inp: str, start: str, end: str) -> Tuple[List[str], str]:
    """Trim a clip. Re-encodes for a frame-accurate cut across containers."""
    out = _output_url(inp, "-clip", "mp4")
    return (["-ss", start, "-to", end, "-i", inp,
             "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", out], out)