from __future__ import annotations

import base64
import json
import tempfile
import unittest
from pathlib import Path

from cdrom_dump_tools.models import AIConfiguration, AppPaths, ConversionOptions, build_command, build_environment, safe_command_preview
from cdrom_dump_tools.protocol import RELEASE_SELECTION_PREFIX, parse_progress, parse_release_candidates
from cdrom_dump_tools.settings import SettingsStore


class ReleaseProtocolTests(unittest.TestCase):
    def make_line(self, payload: object) -> str:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        return RELEASE_SELECTION_PREFIX + base64.b64encode(raw).decode("ascii")

    def test_parses_unicode_candidates(self) -> None:
        candidates = parse_release_candidates(
            self.make_line(
                [
                    {"index": 1, "artist": "宇多田ヒカル", "title": "One Last Kiss"},
                    {"index": 2, "artist": "宇多田光", "title": "One Last Kiss"},
                ]
            )
        )
        self.assertEqual([1, 2], [candidate.index for candidate in candidates])
        self.assertEqual("宇多田ヒカル", candidates[0].artist)

    def test_rejects_duplicate_and_discontinuous_indexes(self) -> None:
        with self.assertRaises(ValueError):
            parse_release_candidates(self.make_line([{"index": 1, "title": "A"}, {"index": 1, "title": "B"}]))
        with self.assertRaises(ValueError):
            parse_release_candidates(self.make_line([{"index": 1, "title": "A"}, {"index": 3, "title": "B"}]))


class CommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.paths = AppPaths(Path("/opt/app"), Path("/opt/app/pwsh"), Path("/opt/app/converter.ps1"), Path("/usr/bin/ffmpeg"))

    def test_builds_full_gui_protocol_command_without_secrets(self) -> None:
        options = ConversionOptions(
            bin_path="/music/a quote's.bin",
            toc_path="/music/a quote's.toc",
            verify_audio=True,
            release_index=0,
            translation_fallback="Auto",
        )
        command = build_command(options, self.paths, require_files=False)
        preview = safe_command_preview(command)
        self.assertIn("-GuiReleaseSelection", command)
        self.assertIn("-VerifyAudio", command)
        self.assertIn("a quote", preview)
        ai = AIConfiguration(openai_api_key="never-show-this", openai_model="gpt-test")
        environment = build_environment(options, ai, self.paths)
        self.assertEqual("never-show-this", environment["OPENAI_API_KEY"])
        self.assertNotIn("never-show-this", preview)

    def test_default_gui_ai_values_do_not_override_dotenv(self) -> None:
        options = ConversionOptions(
            bin_path="/music/disc.bin",
            toc_path="/music/disc.toc",
            env_path="/music/custom.env",
            translation_fallback="Auto",
        )
        environment = build_environment(options, AIConfiguration(), self.paths)
        for name in (
            "GOOGLE_TRANSLATE_BASE_URL",
            "MICROSOFT_TRANSLATOR_BASE_URL",
            "OPENAI_BASE_URL",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_VERSION",
            "ANTHROPIC_MAX_TOKENS",
        ):
            self.assertNotIn(name, environment)

        configured = AIConfiguration(openai_model="custom-model", openai_base_url="https://example.test/v1")
        configured_environment = build_environment(options, configured, self.paths)
        self.assertEqual("custom-model", configured_environment["OPENAI_MODEL"])
        self.assertEqual("https://example.test/v1", configured_environment["OPENAI_BASE_URL"])

    def test_progress_parser_covers_conversion_and_verification(self) -> None:
        converting = parse_progress("Converting track 3/8 -> 03 - Song.flac")
        verified = parse_progress("Verified track 8/8: lossless PCM SHA-256 match")
        self.assertEqual(("track_started", 3, 8), (converting.kind, converting.current, converting.total))
        self.assertEqual(("track_verified", 8, 8), (verified.kind, verified.current, verified.total))


class SettingsTests(unittest.TestCase):
    def test_settings_file_never_contains_api_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            store = SettingsStore(path)
            ai = AIConfiguration(openai_api_key="openai-secret", anthropic_api_key="anthropic-secret", openai_model="model")
            store.save(ConversionOptions(), ai, True)
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("openai-secret", text)
            self.assertNotIn("anthropic-secret", text)
            options, loaded_ai, remember = store.load()
            self.assertIsInstance(options, ConversionOptions)
            self.assertEqual("model", loaded_ai.openai_model)
            self.assertTrue(remember)


if __name__ == "__main__":
    unittest.main()
