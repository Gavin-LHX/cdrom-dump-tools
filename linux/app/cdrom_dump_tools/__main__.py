from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys

from .models import (
    APP_NAME,
    VERSION,
    AIConfiguration,
    AppPaths,
    ConversionOptions,
    build_command,
    build_environment,
    safe_command_preview,
)
from .protocol import RELEASE_SELECTION_PREFIX, parse_progress, parse_release_candidates


def run_self_test() -> int:
    paths = AppPaths.discover()
    paths.validate()
    candidates = [
        {"index": 1, "artist": "艺术家", "title": "专辑 A", "date": "2026", "country": "JP", "disc": "1"},
        {"index": 2, "artist": "Artist", "title": "Album B", "date": "2025", "country": "US", "disc": "1"},
    ]
    protocol_line = RELEASE_SELECTION_PREFIX + base64.b64encode(
        json.dumps(candidates, ensure_ascii=False).encode("utf-8")
    ).decode("ascii")
    parsed = parse_release_candidates(protocol_line)
    if len(parsed) != 2 or parsed[0].title != "专辑 A":
        raise RuntimeError("MusicBrainz 候选协议自检失败。")
    if parse_progress("Verified track 2/2: lossless PCM SHA-256 match") is None:
        raise RuntimeError("进度解析自检失败。")

    options = ConversionOptions(bin_path="/tmp/disc with quote's.bin", toc_path="/tmp/disc.toc")
    command = build_command(options, paths, require_files=False)
    preview = safe_command_preview(command)
    ai = AIConfiguration(openai_api_key="self-test-secret", openai_model="test-model")
    environment = build_environment(options, ai, paths)
    if "self-test-secret" in preview or environment.get("OPENAI_API_KEY") != "self-test-secret":
        raise RuntimeError("API Key 隔离自检失败。")

    powershell = subprocess.run(
        [str(paths.powershell), "-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
        env={**os.environ, "POWERSHELL_TELEMETRY_OPTOUT": "1"},
    )
    if powershell.returncode != 0 or not powershell.stdout.strip():
        raise RuntimeError(f"内置 PowerShell 自检失败：{powershell.stderr.strip()}")
    ffmpeg = subprocess.run(
        [str(paths.ffmpeg), "-version"],
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    if ffmpeg.returncode != 0 or "ffmpeg version" not in ffmpeg.stdout.lower():
        raise RuntimeError("FFmpeg 自检失败。")
    print(
        json.dumps(
            {
                "application": APP_NAME,
                "version": VERSION,
                "powershell": powershell.stdout.strip(),
                "ffmpeg": ffmpeg.stdout.splitlines()[0].strip(),
                "converter": str(paths.converter),
                "release_protocol": "passed",
                "progress_parser": "passed",
                "secret_redaction": "passed",
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cdrom-dump-tools", description="GNOME frontend for CD-ROM Dump Tools")
    parser.add_argument("--version", action="store_true", help="show the application version")
    parser.add_argument("--self-test", action="store_true", help="validate installed runtime and protocol helpers")
    parser.add_argument("--smoke-test", action="store_true", help="open the GNOME UI briefly, then exit")
    arguments = parser.parse_args(argv)
    if arguments.version:
        print(f"{APP_NAME} {VERSION}")
        return 0
    if arguments.self_test:
        return run_self_test()
    from .ui import CdromApplication

    application = CdromApplication(smoke_test=arguments.smoke_test)
    return int(application.run([sys.argv[0]]))


if __name__ == "__main__":
    raise SystemExit(main())
