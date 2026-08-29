from __future__ import annotations

import base64
import dataclasses
import json
import re

RELEASE_SELECTION_PREFIX = "CDROM_DUMP_TOOLS_RELEASE_SELECTION_V1:"
MAXIMUM_ENCODED_LENGTH = 1_000_000
MAXIMUM_TEXT_LENGTH = 500


@dataclasses.dataclass(frozen=True)
class ReleaseCandidate:
    index: int
    artist: str
    title: str
    date: str
    country: str
    disc: str
    release_id: str
    barcode: str


@dataclasses.dataclass(frozen=True)
class ProgressEvent:
    kind: str
    current: int | None = None
    total: int | None = None
    detail: str = ""


def is_release_selection_line(line: str) -> bool:
    return line.startswith(RELEASE_SELECTION_PREFIX)


def parse_release_candidates(line: str) -> list[ReleaseCandidate]:
    if not is_release_selection_line(line):
        raise ValueError("不是候选专辑选择协议行。")
    encoded = line[len(RELEASE_SELECTION_PREFIX) :]
    if not encoded or len(encoded) > MAXIMUM_ENCODED_LENGTH:
        raise ValueError("候选专辑数据长度无效。")
    try:
        raw = base64.b64decode(encoded, validate=True)
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("候选专辑数据无法解析。") from error
    if not isinstance(payload, list) or not 2 <= len(payload) <= 1000:
        raise ValueError("候选专辑数量无效。")

    candidates: list[ReleaseCandidate] = []
    indexes: set[int] = set()
    for item in payload:
        if not isinstance(item, dict) or isinstance(item.get("index"), bool):
            raise ValueError("候选专辑条目格式无效。")
        try:
            index = int(item.get("index"))
        except (TypeError, ValueError) as error:
            raise ValueError("候选专辑序号无效。") from error
        if not 1 <= index <= 1000 or index in indexes:
            raise ValueError("候选专辑序号无效或重复。")
        indexes.add(index)
        title = _clean(item.get("title"))
        if not title:
            raise ValueError("候选专辑缺少标题。")
        candidates.append(
            ReleaseCandidate(
                index=index,
                artist=_clean(item.get("artist")) or "未知艺术家",
                title=title,
                date=_clean(item.get("date")),
                country=_clean(item.get("country")),
                disc=_clean(item.get("disc")),
                release_id=_clean(item.get("release_id")),
                barcode=_clean(item.get("barcode")),
            )
        )
    candidates.sort(key=lambda candidate: candidate.index)
    if [candidate.index for candidate in candidates] != list(range(1, len(candidates) + 1)):
        raise ValueError("候选专辑序号不连续。")
    return candidates


def parse_progress(line: str) -> ProgressEvent | None:
    if line.startswith("MusicBrainz Disc ID:") or line.startswith("Matched release:"):
        return ProgressEvent("metadata")
    match = re.fullmatch(r"Lyrics (?P<current>\d{2,3}):\s*(?P<detail>.*)", line)
    if match:
        return ProgressEvent("lyrics", _positive(match.group("current")), detail=_detail(match.group("detail")))
    if line.startswith("Trying cover source: "):
        detail = _detail(line.removeprefix("Trying cover source: "))
        return ProgressEvent("cover", detail=detail) if detail else None
    match = re.fullmatch(r"Tracks:\s*(?P<total>\d+)", line)
    if match:
        return ProgressEvent("track_count", total=_positive(match.group("total")))
    for expression, kind in (
        (r"Converting track (?P<current>\d+)/(?P<total>\d+) -> (?P<detail>.+)", "track_started"),
        (r"Verifying track (?P<current>\d+)/(?P<total>\d+) -> (?P<detail>.+)", "verification_started"),
    ):
        match = re.fullmatch(expression, line)
        if match:
            current = _positive(match.group("current"))
            total = _positive(match.group("total"))
            if current > total:
                return None
            return ProgressEvent(kind, current, total, _detail(match.group("detail")))
    match = re.fullmatch(r"Verified track (?P<current>\d+)/(?P<total>\d+): lossless PCM SHA-256 match", line)
    if match:
        current = _positive(match.group("current"))
        total = _positive(match.group("total"))
        if current <= total:
            return ProgressEvent("track_verified", current, total)
    return None


def _clean(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return value.replace("\r", " ").replace("\n", " ").strip()[:MAXIMUM_TEXT_LENGTH]


def _detail(value: str) -> str:
    text = value.replace("\r", " ").replace("\n", " ").strip()
    return text if len(text) <= 120 else text[:120] + "…"


def _positive(value: str) -> int:
    number = int(value)
    if not 1 <= number <= 10_000:
        raise ValueError("进度数字超出允许范围。")
    return number
