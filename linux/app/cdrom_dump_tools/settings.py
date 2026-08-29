from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

from .models import AIConfiguration, APP_ID, ConversionOptions

MAXIMUM_SETTINGS_BYTES = 1_000_000


class SettingsStore:
    def __init__(self, path: Path | None = None) -> None:
        config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        self.path = path or config_home / "cdrom-dump-tools" / "settings.json"

    def load(self) -> tuple[ConversionOptions, AIConfiguration, bool]:
        if not self.path.is_file() or self.path.is_symlink():
            return ConversionOptions(), AIConfiguration(), False
        try:
            if self.path.stat().st_size > MAXIMUM_SETTINGS_BYTES:
                raise ValueError("设置文件过大。")
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            return ConversionOptions(), AIConfiguration(), False
        if not isinstance(payload, dict):
            return ConversionOptions(), AIConfiguration(), False
        return (
            ConversionOptions.from_dict(payload.get("conversion")),
            AIConfiguration.from_public_dict(payload.get("ai")),
            payload.get("remember_api_keys") is True,
        )

    def save(self, options: ConversionOptions, ai: AIConfiguration, remember_api_keys: bool) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        payload = {
            "schema": 1,
            "conversion": options.persisted_dict(),
            "ai": ai.public_dict(),
            "remember_api_keys": bool(remember_api_keys),
        }
        serialized = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
        descriptor, temporary_name = tempfile.mkstemp(prefix=".settings-", suffix=".json", dir=self.path.parent)
        temporary_path = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(serialized)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, self.path)
            os.chmod(self.path, 0o600)
        finally:
            try:
                temporary_path.unlink(missing_ok=True)
            except OSError:
                pass


class SecretStore:
    def __init__(self, executable: str = "secret-tool") -> None:
        self.executable = executable

    def available(self) -> bool:
        from shutil import which

        return which(self.executable) is not None

    def load_into(self, ai: AIConfiguration) -> None:
        if not self.available():
            return
        for field in AIConfiguration.SECRET_FIELDS:
            value = self._lookup(field)
            if value is not None:
                setattr(ai, field, value)

    def save_from(self, ai: AIConfiguration) -> None:
        if not self.available():
            raise RuntimeError("系统没有 secret-tool，无法把 API Key 保存到 GNOME Keyring。")
        for field in AIConfiguration.SECRET_FIELDS:
            value = getattr(ai, field).strip()
            if value:
                result = subprocess.run(
                    [
                        self.executable,
                        "store",
                        f"--label=CD-ROM Dump Tools · {field}",
                        "application",
                        APP_ID,
                        "field",
                        field,
                    ],
                    input=value,
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=30,
                )
                if result.returncode != 0:
                    raise RuntimeError(f"GNOME Keyring 无法保存 {field}。")
            else:
                self._clear(field)

    def clear(self) -> None:
        if not self.available():
            raise RuntimeError("系统没有 secret-tool，无法确认 GNOME Keyring 中的 API Key 已清除。")
        for field in AIConfiguration.SECRET_FIELDS:
            self._clear(field)

    def _clear(self, field: str) -> None:
        if self._lookup(field) is None:
            return
        result = subprocess.run(
            [self.executable, "clear", "application", APP_ID, "field", field],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit code {result.returncode}"
            raise RuntimeError(f"GNOME Keyring 无法清除 {field}：{detail}")
        if self._lookup(field) is not None:
            raise RuntimeError(f"GNOME Keyring 报告已清除 {field}，但复查时该 Key 仍然存在。")

    def _lookup(self, field: str) -> str | None:
        result = subprocess.run(
            [self.executable, "lookup", "application", APP_ID, "field", field],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.rstrip("\r\n")
        if result.returncode == 1 and not result.stderr.strip():
            return None
        detail = result.stderr.strip() or f"exit code {result.returncode}"
        raise RuntimeError(f"GNOME Keyring 无法读取 {field}：{detail}")
