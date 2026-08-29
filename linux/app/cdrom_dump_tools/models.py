from __future__ import annotations

import dataclasses
import os
import shlex
import shutil
from pathlib import Path
from urllib.parse import urlsplit

APP_ID = "io.github.gavinlhx.CdromDumpTools"
APP_NAME = "CD-ROM Dump Tools"
VERSION = "2.15.1"
REPOSITORY_URL = "https://github.com/Gavin-LHX/cdrom-dump-tools"
DEFAULT_USER_AGENT = f"CdromDumpToolsLinux/{VERSION} ({REPOSITORY_URL})"

TRANSLATION_MODES = (
    ("Auto", "自动：AI → Google/Microsoft → GTX → Bing"),
    ("AIThenGoogle", "AI 优先，随后机器翻译"),
    ("GoogleThenAI", "机器翻译优先，随后 AI"),
    ("AI", "仅 AI"),
    ("Google", "仅 Google/Microsoft/免 Key 回退"),
    ("None", "不进行机器翻译"),
)
AI_PROVIDERS = (("Auto", "自动"), ("OpenAI", "OpenAI-compatible"), ("Anthropic", "Anthropic-compatible"))
DOMESTIC_PRIORITIES = (("NetEaseFirst", "网易云优先"), ("QQMusicFirst", "QQ 音乐优先"))


@dataclasses.dataclass(frozen=True)
class AppPaths:
    root: Path
    powershell: Path
    converter: Path
    ffmpeg: Path

    @classmethod
    def discover(cls) -> "AppPaths":
        override = os.environ.get("CDROM_DUMP_TOOLS_ROOT", "").strip()
        if override:
            root = Path(override).expanduser().resolve()
        else:
            root = Path(__file__).resolve().parents[2]
            if root.name == "linux":
                root = root.parent

        bundled_converter = root / "converter" / "bin_to_audio_windows.ps1"
        source_converter = root / "bin_to_audio_windows.ps1"
        converter = bundled_converter if bundled_converter.is_file() else source_converter

        bundled_pwsh = root / "runtime" / "powershell" / "pwsh"
        system_pwsh = shutil.which("pwsh")
        powershell = bundled_pwsh if bundled_pwsh.is_file() else Path(system_pwsh or "/nonexistent/pwsh")

        system_ffmpeg = shutil.which("ffmpeg")
        ffmpeg = Path(system_ffmpeg or "/usr/bin/ffmpeg")
        return cls(root=root, powershell=powershell, converter=converter, ffmpeg=ffmpeg)

    def validate(self) -> None:
        failures: list[str] = []
        for label, path in (
            ("内置 PowerShell", self.powershell),
            ("转换脚本", self.converter),
            ("FFmpeg", self.ffmpeg),
        ):
            if not path.is_file():
                failures.append(f"{label}不存在：{path}")
            elif label != "转换脚本" and not os.access(path, os.X_OK):
                failures.append(f"{label}不可执行：{path}")
        if failures:
            raise ValueError("\n".join(failures))


@dataclasses.dataclass
class AIConfiguration:
    DEFAULT_GOOGLE_BASE_URL = "https://translation.googleapis.com/language/translate/v2"
    DEFAULT_MICROSOFT_BASE_URL = "https://api.cognitive.microsofttranslator.com"
    DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"
    DEFAULT_ANTHROPIC_BASE_URL = "https://api.anthropic.com/v1"
    DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
    DEFAULT_ANTHROPIC_MAX_TOKENS = 4096

    google_api_key: str = ""
    google_base_url: str = DEFAULT_GOOGLE_BASE_URL
    microsoft_api_key: str = ""
    microsoft_base_url: str = DEFAULT_MICROSOFT_BASE_URL
    microsoft_region: str = ""
    openai_api_key: str = ""
    openai_base_url: str = DEFAULT_OPENAI_BASE_URL
    openai_model: str = ""
    openai_org_id: str = ""
    openai_project_id: str = ""
    anthropic_api_key: str = ""
    anthropic_base_url: str = DEFAULT_ANTHROPIC_BASE_URL
    anthropic_model: str = ""
    anthropic_version: str = DEFAULT_ANTHROPIC_VERSION
    anthropic_max_tokens: int = DEFAULT_ANTHROPIC_MAX_TOKENS
    prompt_file: str = ""

    SECRET_FIELDS = (
        "google_api_key",
        "microsoft_api_key",
        "openai_api_key",
        "anthropic_api_key",
    )

    def public_dict(self) -> dict[str, object]:
        result = dataclasses.asdict(self)
        for name in self.SECRET_FIELDS:
            result.pop(name, None)
        return result

    @classmethod
    def from_public_dict(cls, values: object) -> "AIConfiguration":
        configuration = cls()
        if not isinstance(values, dict):
            return configuration
        for field in dataclasses.fields(configuration):
            if field.name in cls.SECRET_FIELDS or field.name not in values:
                continue
            value = values[field.name]
            if field.name == "anthropic_max_tokens":
                try:
                    value = min(32768, max(256, int(value)))
                except (TypeError, ValueError):
                    continue
            elif not isinstance(value, str):
                continue
            setattr(configuration, field.name, value)
        return configuration


@dataclasses.dataclass
class ConversionOptions:
    bin_path: str = ""
    toc_path: str = ""
    output_directory: str = ""
    env_path: str = ""
    format: str = "flac"
    include_metadata: bool = True
    include_cover: bool = True
    include_lyrics: bool = True
    use_netease: bool = True
    use_qqmusic: bool = True
    verify_audio: bool = True
    domestic_priority: str = "NetEaseFirst"
    translation_fallback: str = "Auto"
    ai_provider: str = "Auto"
    release_index: int = 0
    musicbrainz_user_agent: str = DEFAULT_USER_AGENT
    open_output_on_success: bool = True

    def normalized(self, require_files: bool = True) -> "ConversionOptions":
        result = dataclasses.replace(self)
        result.bin_path = _normalize_path(result.bin_path)
        if not result.bin_path:
            raise ValueError("请选择 BIN 光盘镜像。")
        if Path(result.bin_path).suffix.lower() != ".bin":
            raise ValueError("BIN 镜像必须使用 .bin 扩展名。")
        if require_files and not Path(result.bin_path).is_file():
            raise ValueError(f"BIN 镜像不存在：{result.bin_path}")

        result.toc_path = _normalize_path(result.toc_path) or str(Path(result.bin_path).with_suffix(".toc"))
        if require_files and not Path(result.toc_path).is_file():
            raise ValueError(f"TOC 文件不存在：{result.toc_path}")
        result.output_directory = _normalize_path(result.output_directory)
        result.env_path = _normalize_path(result.env_path)
        if require_files and result.env_path and not Path(result.env_path).is_file():
            raise ValueError(f".env 文件不存在：{result.env_path}")

        if result.format not in {"flac", "wav"}:
            raise ValueError("输出格式只能是 FLAC 或 WAV。")
        if result.translation_fallback not in {item[0] for item in TRANSLATION_MODES}:
            raise ValueError("歌词翻译回退设置无效。")
        if result.ai_provider not in {item[0] for item in AI_PROVIDERS}:
            raise ValueError("AI Provider 设置无效。")
        if result.domestic_priority not in {item[0] for item in DOMESTIC_PRIORITIES}:
            raise ValueError("国内源优先级设置无效。")
        if not 0 <= int(result.release_index) <= 1000:
            raise ValueError("候选专辑序号必须位于 0–1000。")
        result.release_index = int(result.release_index)
        result.musicbrainz_user_agent = result.musicbrainz_user_agent.strip() or DEFAULT_USER_AGENT
        return result

    def persisted_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, values: object) -> "ConversionOptions":
        options = cls()
        if not isinstance(values, dict):
            return options
        for field in dataclasses.fields(options):
            if field.name not in values:
                continue
            value = values[field.name]
            current = getattr(options, field.name)
            if isinstance(current, bool) and isinstance(value, bool):
                setattr(options, field.name, value)
            elif isinstance(current, int) and not isinstance(value, bool):
                try:
                    setattr(options, field.name, int(value))
                except (TypeError, ValueError):
                    pass
            elif isinstance(current, str) and isinstance(value, str):
                setattr(options, field.name, value)
        if options.musicbrainz_user_agent.startswith("CdromDumpToolsLinux/") and options.musicbrainz_user_agent.endswith(
            f" ({REPOSITORY_URL})"
        ):
            options.musicbrainz_user_agent = DEFAULT_USER_AGENT
        return options


def build_command(options: ConversionOptions, paths: AppPaths, require_files: bool = True) -> list[str]:
    values = options.normalized(require_files=require_files)
    command = [
        str(paths.powershell),
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        str(paths.converter),
        "-BinPath",
        values.bin_path,
        "-Format",
        values.format,
        "-TocPath",
        values.toc_path,
        "-FfmpegPath",
        str(paths.ffmpeg),
    ]
    if values.output_directory:
        command.extend(("-OutputDirectory", values.output_directory))
    if not values.include_metadata:
        command.append("-NoMetadata")
    if not values.include_cover:
        command.append("-NoCover")
    if not values.include_lyrics:
        command.append("-NoLyrics")
    if not values.use_netease:
        command.append("-NoNetEase")
    if not values.use_qqmusic:
        command.append("-NoQQMusic")
    if values.verify_audio:
        command.append("-VerifyAudio")
    command.append("-NoPause")
    if values.include_metadata and values.release_index == 0:
        command.append("-GuiReleaseSelection")
    command.extend(
        (
            "-LyricsTranslationFallback",
            values.translation_fallback,
            "-AiTranslationProvider",
            values.ai_provider,
            "-DomesticSourcePriority",
            values.domestic_priority,
            "-ReleaseIndex",
            str(values.release_index),
            "-MusicBrainzUserAgent",
            values.musicbrainz_user_agent,
        )
    )
    if values.env_path:
        command.extend(("-EnvPath", values.env_path))
    return command


def safe_command_preview(command: list[str]) -> str:
    return " ".join(shlex.quote(value) for value in command)


def build_environment(options: ConversionOptions, ai: AIConfiguration, paths: AppPaths) -> dict[str, str]:
    environment: dict[str, str] = {}
    for name in (
        "HOME",
        "TMPDIR",
        "LANG",
        "LANGUAGE",
        "LC_ALL",
        "LC_CTYPE",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "XDG_CACHE_HOME",
        "DBUS_SESSION_BUS_ADDRESS",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "https_proxy",
        "http_proxy",
        "no_proxy",
    ):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    environment.setdefault("HOME", str(Path.home()))
    environment.setdefault("TMPDIR", "/tmp")
    environment["PATH"] = f"{paths.powershell.parent}:/usr/local/bin:/usr/bin:/bin"
    environment["PWD"] = str(paths.converter.parent)
    environment["DOTNET_NOLOGO"] = "1"
    environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1"

    if not options.include_lyrics or options.translation_fallback == "None":
        return environment

    use_machine_translation = options.translation_fallback in {"Auto", "AIThenGoogle", "GoogleThenAI", "Google"}
    use_ai_translation = options.translation_fallback in {"Auto", "AIThenGoogle", "GoogleThenAI", "AI"}

    google_configured = use_machine_translation and (
        bool(ai.google_api_key.strip()) or not _same_url(ai.google_base_url, AIConfiguration.DEFAULT_GOOGLE_BASE_URL)
    )
    if google_configured:
        _put(environment, "GOOGLE_TRANSLATE_API_KEY", ai.google_api_key)
        _put(environment, "GOOGLE_TRANSLATE_BASE_URL", ai.google_base_url)

    microsoft_configured = use_machine_translation and (
        bool(ai.microsoft_api_key.strip())
        or bool(ai.microsoft_region.strip())
        or not _same_url(ai.microsoft_base_url, AIConfiguration.DEFAULT_MICROSOFT_BASE_URL)
    )
    if microsoft_configured:
        _put(environment, "MICROSOFT_TRANSLATOR_API_KEY", ai.microsoft_api_key)
        _put(environment, "MICROSOFT_TRANSLATOR_BASE_URL", ai.microsoft_base_url)
        _put(environment, "MICROSOFT_TRANSLATOR_REGION", ai.microsoft_region)

    openai_configured = use_ai_translation and options.ai_provider in {"Auto", "OpenAI"} and (
        bool(ai.openai_api_key.strip())
        or bool(ai.openai_model.strip())
        or bool(ai.openai_org_id.strip())
        or bool(ai.openai_project_id.strip())
        or not _same_url(ai.openai_base_url, AIConfiguration.DEFAULT_OPENAI_BASE_URL)
    )
    if openai_configured:
        _put(environment, "OPENAI_API_KEY", ai.openai_api_key)
        _put(environment, "OPENAI_BASE_URL", ai.openai_base_url)
        _put(environment, "OPENAI_MODEL", ai.openai_model)
        _put(environment, "OPENAI_ORG_ID", ai.openai_org_id)
        _put(environment, "OPENAI_PROJECT_ID", ai.openai_project_id)

    anthropic_configured = use_ai_translation and options.ai_provider in {"Auto", "Anthropic"} and (
        bool(ai.anthropic_api_key.strip())
        or bool(ai.anthropic_model.strip())
        or not _same_url(ai.anthropic_base_url, AIConfiguration.DEFAULT_ANTHROPIC_BASE_URL)
        or ai.anthropic_version.strip() != AIConfiguration.DEFAULT_ANTHROPIC_VERSION
        or ai.anthropic_max_tokens != AIConfiguration.DEFAULT_ANTHROPIC_MAX_TOKENS
    )
    if anthropic_configured:
        _put(environment, "ANTHROPIC_API_KEY", ai.anthropic_api_key)
        _put(environment, "ANTHROPIC_BASE_URL", ai.anthropic_base_url)
        _put(environment, "ANTHROPIC_MODEL", ai.anthropic_model)
        _put(environment, "ANTHROPIC_VERSION", ai.anthropic_version)
        environment["ANTHROPIC_MAX_TOKENS"] = str(ai.anthropic_max_tokens)
    if use_ai_translation:
        _put(environment, "AI_TRANSLATION_PROMPT_FILE", _normalize_path(ai.prompt_file))
    return environment


def validate_ai_configuration(ai: AIConfiguration) -> None:
    for label, value in (
        ("Google Base URL", ai.google_base_url),
        ("Microsoft Base URL", ai.microsoft_base_url),
        ("OpenAI Base URL", ai.openai_base_url),
        ("Anthropic Base URL", ai.anthropic_base_url),
    ):
        parsed = urlsplit(value.strip())
        if parsed.scheme not in {"https", "http"} or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError(f"{label} 必须是无账号、密码、查询参数和片段的 HTTP(S) API 根地址。")
    if not 256 <= int(ai.anthropic_max_tokens) <= 32768:
        raise ValueError("Anthropic Max Tokens 必须位于 256–32768。")


def ai_summary(ai: AIConfiguration) -> str:
    configured: list[str] = []
    if ai.openai_api_key and ai.openai_model:
        configured.append(f"OpenAI ({ai.openai_model})")
    if ai.anthropic_api_key and ai.anthropic_model:
        configured.append(f"Anthropic ({ai.anthropic_model})")
    if ai.google_api_key:
        configured.append("Google Cloud")
    if ai.microsoft_api_key:
        configured.append("Microsoft Azure")
    return " → ".join(configured) if configured else "未配置付费服务；仍可使用 .env、Google GTX 与 Bing 免 Key 回退"


def _normalize_path(value: str) -> str:
    stripped = value.strip()
    return str(Path(stripped).expanduser().resolve(strict=False)) if stripped else ""


def _put(environment: dict[str, str], name: str, value: str) -> None:
    stripped = value.strip()
    if stripped:
        environment[name] = stripped


def _same_url(value: str, default: str) -> bool:
    return value.strip().rstrip("/").casefold() == default.rstrip("/").casefold()
