from __future__ import annotations

import dataclasses
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from .models import (
    AI_PROVIDERS,
    APP_ID,
    APP_NAME,
    DOMESTIC_PRIORITIES,
    TRANSLATION_MODES,
    AIConfiguration,
    AppPaths,
    ConversionOptions,
    ai_summary,
    build_command,
    safe_command_preview,
    validate_ai_configuration,
)
from .protocol import ProgressEvent, ReleaseCandidate, parse_progress
from .runner import ConversionRunner
from .settings import SecretStore, SettingsStore


class CdromApplication(Adw.Application):
    def __init__(self, smoke_test: bool = False) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.smoke_test = smoke_test
        self.window: MainWindow | None = None

    def do_activate(self) -> None:
        if self.window is None:
            self.window = MainWindow(self)
        self.window.present()
        if self.smoke_test:
            GLib.timeout_add(750, self._finish_smoke_test)

    def _finish_smoke_test(self) -> bool:
        self.quit()
        return GLib.SOURCE_REMOVE


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, application: CdromApplication) -> None:
        super().__init__(application=application)
        self.set_title(APP_NAME)
        self.set_default_size(1080, 780)
        self.set_size_request(760, 620)

        self.paths = AppPaths.discover()
        self.settings_store = SettingsStore()
        self.secret_store = SecretStore()
        self.options, self.ai, self.remember_api_keys = self.settings_store.load()
        if self.remember_api_keys:
            try:
                self.secret_store.load_into(self.ai)
            except (OSError, RuntimeError, subprocess.SubprocessError):
                self.remember_api_keys = False

        self.runner = ConversionRunner(self._queue_log, self._queue_release_selection, self._queue_finished)
        self.log_queue: queue.Queue[tuple[str, bool]] = queue.Queue()
        self.started_at: float | None = None
        self.last_output_directory: str | None = None
        self.release_window: Adw.Window | None = None
        self._manual_close = False
        self._pulse_mode = False
        self._loading_widgets = True

        self._build_ui()
        try:
            self._load_widgets()
        finally:
            self._loading_widgets = False
        self._update_preview()
        self._update_ai_summary()
        GLib.timeout_add(60, self._drain_log_queue)
        GLib.timeout_add(150, self._pulse_progress)
        GLib.timeout_add_seconds(1, self._update_elapsed)
        self.connect("close-request", self._on_close_request)

    def _build_ui(self) -> None:
        self.overlay = Adw.ToastOverlay()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.overlay.set_child(root)
        self.set_content(self.overlay)

        header = Adw.HeaderBar()
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        title = Gtk.Label(label="CD 光盘镜像转换")
        title.add_css_class("title-2")
        title.set_xalign(0)
        self.phase_label = Gtk.Label(label="请选择 BIN/TOC 镜像")
        self.phase_label.add_css_class("dim-label")
        self.phase_label.set_xalign(0)
        self.phase_label.set_ellipsize(3)
        title_box.append(title)
        title_box.append(self.phase_label)
        header.set_title_widget(title_box)
        self.ai_button = Gtk.Button.new_from_icon_name("preferences-system-symbolic")
        self.ai_button.set_tooltip_text("配置 AI 模型与 API Key")
        self.ai_button.connect("clicked", self._show_ai_settings)
        header.pack_end(self.ai_button)
        root.append(header)

        hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        hero.set_margin_start(20)
        hero.set_margin_end(20)
        hero.set_margin_top(12)
        hero.set_margin_bottom(10)
        status_line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.status_label = Gtk.Label(label="就绪")
        self.status_label.add_css_class("heading")
        self.status_label.set_xalign(0)
        status_line.append(self.status_label)
        status_line.append(Gtk.Box(hexpand=True))
        self.elapsed_label = Gtk.Label(label="00:00")
        self.elapsed_label.add_css_class("numeric")
        self.elapsed_label.add_css_class("dim-label")
        status_line.append(self.elapsed_label)
        hero.append(status_line)
        self.progress = Gtk.ProgressBar(show_text=False)
        hero.append(self.progress)
        root.append(hero)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=160)
        self.stack.set_vexpand(True)
        self.preferences_page = self._build_preferences_page()
        self.log_page = self._build_log_page()
        self.preview_page = self._build_preview_page()
        self.stack.add_titled(self.preferences_page, "settings", "转换设置")
        self.stack.add_titled(self.log_page, "logs", "运行日志")
        self.stack.add_titled(self.preview_page, "preview", "命令预览")

        switcher = Gtk.StackSwitcher(stack=self.stack)
        switcher.set_halign(Gtk.Align.CENTER)
        switcher.set_margin_bottom(6)
        root.append(switcher)
        root.append(self.stack)

        action_bar = Gtk.ActionBar()
        self.start_button = Gtk.Button(label="开始转换")
        self.start_button.add_css_class("suggested-action")
        self.start_button.connect("clicked", self._start_conversion)
        self.cancel_button = Gtk.Button(label="停止转换", sensitive=False)
        self.cancel_button.add_css_class("destructive-action")
        self.cancel_button.connect("clicked", lambda _button: self.runner.cancel())
        self.open_button = Gtk.Button(label="打开输出目录", sensitive=False)
        self.open_button.connect("clicked", lambda _button: self._open_output())
        action_bar.pack_start(self.start_button)
        action_bar.pack_start(self.cancel_button)
        action_bar.pack_end(self.open_button)
        root.append(action_bar)

    def _build_preferences_page(self) -> Adw.PreferencesPage:
        page = Adw.PreferencesPage()

        files = Adw.PreferencesGroup(title="输入与输出", description="选择 BIN/TOC 后即可开始；输出留空时按识别出的专辑自动命名。")
        self.bin_row = self._path_row("BIN 镜像（必选）", "原始 CD-DA .bin 文件", "bin", False)
        self.toc_row = self._path_row("TOC 文件", "留空时使用同名 .toc", "toc", False, clear=True)
        self.output_row = self._path_row("自定义输出目录", "留空时按专辑信息自动命名", None, True, clear=True)
        self.env_row = self._path_row(".env 文件", "可选；API Key 不会显示在命令预览中", "env", False, clear=True)
        for row in (self.bin_row, self.toc_row, self.output_row, self.env_row):
            files.add(row)
        page.add(files)

        conversion = Adw.PreferencesGroup(title="转换与标签")
        self.format_row = self._combo_row("输出格式", (("flac", "FLAC（无损压缩，推荐）"), ("wav", "WAV（未压缩 PCM）")))
        self.metadata_row = Adw.SwitchRow(title="获取并写入在线元数据", subtitle="光盘身份优先 MusicBrainz；标签按国内源优先级补全")
        self.cover_row = Adw.SwitchRow(title="下载并嵌入专辑封面")
        self.lyrics_row = Adw.SwitchRow(title="下载歌词并生成 LRC/SRT", subtitle="网易云 → QQ 音乐 → LRCLIB → 翻译回退")
        self.verify_row = Adw.SwitchRow(title="逐轨无损 PCM 校验（推荐）", subtitle="对 BIN 字节段和成品解码 PCM 比较 SHA-256")
        for row in (self.format_row, self.metadata_row, self.cover_row, self.lyrics_row, self.verify_row):
            conversion.add(row)
        page.add(conversion)

        sources = Adw.PreferencesGroup(title="国内音乐源")
        self.netease_row = Adw.SwitchRow(title="使用网易云音乐")
        self.qq_row = Adw.SwitchRow(title="使用 QQ 音乐")
        self.domestic_row = self._combo_row("标签数据优先级", DOMESTIC_PRIORITIES)
        for row in (self.netease_row, self.qq_row, self.domestic_row):
            sources.add(row)
        page.add(sources)

        translation = Adw.PreferencesGroup(title="歌词与 AI 翻译")
        self.translation_row = self._combo_row("中文翻译回退", TRANSLATION_MODES)
        self.provider_row = self._combo_row("AI 翻译服务", AI_PROVIDERS)
        self.ai_summary_row = Adw.ActionRow(title="模型与 API Key")
        configure_button = Gtk.Button(label="配置…", valign=Gtk.Align.CENTER)
        configure_button.connect("clicked", self._show_ai_settings)
        self.ai_summary_row.add_suffix(configure_button)
        self.ai_summary_row.set_activatable_widget(configure_button)
        for row in (self.translation_row, self.provider_row, self.ai_summary_row):
            translation.add(row)
        page.add(translation)

        advanced = Adw.PreferencesGroup(title="高级设置")
        release_row = Adw.ActionRow(title="MusicBrainz 候选序号", subtitle="0 = 出现多个发行版时弹窗选择")
        adjustment = Gtk.Adjustment(lower=0, upper=1000, step_increment=1, page_increment=10)
        self.release_spin = Gtk.SpinButton(adjustment=adjustment, numeric=True, valign=Gtk.Align.CENTER)
        self.release_spin.set_width_chars(5)
        self.release_spin.connect("value-changed", lambda _widget: self._settings_changed())
        release_row.add_suffix(self.release_spin)
        self.user_agent_row = Adw.EntryRow(title="MusicBrainz User-Agent")
        self.user_agent_row.connect("changed", lambda _widget: self._settings_changed())
        self.open_output_row = Adw.SwitchRow(title="成功后打开输出目录")
        self.open_output_row.connect("notify::active", lambda *_args: self._settings_changed())
        advanced.add(release_row)
        advanced.add(self.user_agent_row)
        advanced.add(self.open_output_row)
        page.add(advanced)
        return page

    def _build_log_page(self) -> Gtk.Box:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.set_margin_start(16)
        page.set_margin_end(16)
        page.set_margin_top(8)
        page.set_margin_bottom(8)
        controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        copy_button = Gtk.Button(label="复制日志")
        copy_button.connect("clicked", self._copy_log)
        clear_button = Gtk.Button(label="清空日志")
        clear_button.connect("clicked", self._clear_log)
        self.follow_logs = Gtk.CheckButton(label="自动跟随最新日志")
        self.follow_logs.set_active(True)
        controls.append(copy_button)
        controls.append(clear_button)
        controls.append(Gtk.Box(hexpand=True))
        controls.append(self.follow_logs)
        page.append(controls)

        self.log_buffer = Gtk.TextBuffer()
        self.error_tag = self.log_buffer.create_tag("error", foreground="#d2463b")
        self.log_view = Gtk.TextView.new_with_buffer(self.log_buffer)
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_monospace(True)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.set_left_margin(10)
        self.log_view.set_right_margin(10)
        self.log_view.set_top_margin(8)
        self.log_view.set_bottom_margin(8)
        self.log_mark = self.log_buffer.create_mark("log-end", self.log_buffer.get_end_iter(), False)
        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.set_child(self.log_view)
        page.append(scroller)
        return page

    def _build_preview_page(self) -> Gtk.Box:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.set_margin_start(16)
        page.set_margin_end(16)
        page.set_margin_top(8)
        page.set_margin_bottom(8)
        description = Gtk.Label(label="预览只显示参数，不读取或暴露 .env、GNOME Keyring 中的 API Key。", xalign=0)
        description.add_css_class("dim-label")
        description.set_wrap(True)
        page.append(description)
        self.preview_buffer = Gtk.TextBuffer()
        self.preview_view = Gtk.TextView.new_with_buffer(self.preview_buffer)
        self.preview_view.set_editable(False)
        self.preview_view.set_cursor_visible(False)
        self.preview_view.set_monospace(True)
        self.preview_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.preview_view.set_left_margin(10)
        self.preview_view.set_right_margin(10)
        self.preview_view.set_top_margin(8)
        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.set_child(self.preview_view)
        page.append(scroller)
        copy_button = Gtk.Button(label="复制命令预览", halign=Gtk.Align.START)
        copy_button.connect("clicked", self._copy_preview)
        page.append(copy_button)
        return page

    def _path_row(self, title: str, subtitle: str, extension: str | None, folder: bool, clear: bool = False) -> Adw.EntryRow:
        row = Adw.EntryRow(title=title)
        row.set_tooltip_text(subtitle)
        browse = Gtk.Button.new_from_icon_name("folder-open-symbolic")
        browse.add_css_class("flat")
        browse.set_tooltip_text("浏览…")
        browse.set_valign(Gtk.Align.CENTER)
        browse.connect("clicked", lambda _button: self._choose_path(row, extension, folder))
        row.add_suffix(browse)
        if clear:
            clear_button = Gtk.Button.new_from_icon_name("edit-clear-symbolic")
            clear_button.add_css_class("flat")
            clear_button.set_tooltip_text("清空")
            clear_button.set_valign(Gtk.Align.CENTER)
            clear_button.connect("clicked", lambda _button: row.set_text(""))
            row.add_suffix(clear_button)
        row.connect("changed", lambda _widget: self._settings_changed())
        return row

    def _combo_row(self, title: str, values: tuple[tuple[str, str], ...]) -> Adw.ComboRow:
        row = Adw.ComboRow(title=title)
        row.set_model(Gtk.StringList.new([label for _value, label in values]))
        row._cdrom_values = [value for value, _label in values]  # type: ignore[attr-defined]
        row.connect("notify::selected", lambda *_args: self._settings_changed())
        return row

    def _load_widgets(self) -> None:
        self.bin_row.set_text(self.options.bin_path)
        self.toc_row.set_text(self.options.toc_path)
        self.output_row.set_text(self.options.output_directory)
        self.env_row.set_text(self.options.env_path)
        self._select_combo(self.format_row, self.options.format)
        self.metadata_row.set_active(self.options.include_metadata)
        self.cover_row.set_active(self.options.include_cover)
        self.lyrics_row.set_active(self.options.include_lyrics)
        self.verify_row.set_active(self.options.verify_audio)
        self.netease_row.set_active(self.options.use_netease)
        self.qq_row.set_active(self.options.use_qqmusic)
        self._select_combo(self.domestic_row, self.options.domestic_priority)
        self._select_combo(self.translation_row, self.options.translation_fallback)
        self._select_combo(self.provider_row, self.options.ai_provider)
        self.release_spin.set_value(self.options.release_index)
        self.user_agent_row.set_text(self.options.musicbrainz_user_agent)
        self.open_output_row.set_active(self.options.open_output_on_success)
        for row in (
            self.metadata_row,
            self.cover_row,
            self.lyrics_row,
            self.verify_row,
            self.netease_row,
            self.qq_row,
        ):
            row.connect("notify::active", lambda *_args: self._settings_changed())

    def _sync_options(self) -> ConversionOptions:
        self.options = ConversionOptions(
            bin_path=self.bin_row.get_text(),
            toc_path=self.toc_row.get_text(),
            output_directory=self.output_row.get_text(),
            env_path=self.env_row.get_text(),
            format=self._combo_value(self.format_row),
            include_metadata=self.metadata_row.get_active(),
            include_cover=self.cover_row.get_active(),
            include_lyrics=self.lyrics_row.get_active(),
            use_netease=self.netease_row.get_active(),
            use_qqmusic=self.qq_row.get_active(),
            verify_audio=self.verify_row.get_active(),
            domestic_priority=self._combo_value(self.domestic_row),
            translation_fallback=self._combo_value(self.translation_row),
            ai_provider=self._combo_value(self.provider_row),
            release_index=self.release_spin.get_value_as_int(),
            musicbrainz_user_agent=self.user_agent_row.get_text(),
            open_output_on_success=self.open_output_row.get_active(),
        )
        return self.options

    def _settings_changed(self) -> None:
        if self._loading_widgets or not hasattr(self, "preview_buffer"):
            return
        self._sync_options()
        self._update_preview()

    def _update_preview(self) -> None:
        try:
            command = build_command(self._sync_options(), self.paths, require_files=False)
            text = safe_command_preview(command)
        except ValueError as error:
            text = f"命令预览暂不可用：{error}"
        self.preview_buffer.set_text(text)

    def _update_ai_summary(self) -> None:
        self.ai_summary_row.set_subtitle(ai_summary(self.ai))

    def _start_conversion(self, _button: Gtk.Button) -> None:
        try:
            if os.geteuid() == 0:
                raise ValueError("为避免高权限进程误用用户文件或 API Key，请以普通用户运行本程序。")
            self.paths.validate()
            options = self._sync_options().normalized(require_files=True)
            validate_ai_configuration(self.ai)
            self.settings_store.save(options, self.ai, self.remember_api_keys)
            command = self.runner.start(options, self.ai, self.paths)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            self._show_error(str(error))
            return

        self.options = options
        self._clear_log(None)
        self.last_output_directory = None
        self.open_button.set_sensitive(False)
        self.preferences_page.set_sensitive(False)
        self.ai_button.set_sensitive(False)
        self.start_button.set_sensitive(False)
        self.cancel_button.set_sensitive(True)
        self.status_label.set_text("正在转换…")
        self.phase_label.set_text("正在准备转换与查询在线信息…")
        self.progress.set_fraction(0)
        self._pulse_mode = True
        self.started_at = time.monotonic()
        self.stack.set_visible_child_name("logs")
        self._queue_log(f"PowerShell: {self.paths.powershell}", False)
        self._queue_log(f"FFmpeg: {self.paths.ffmpeg}", False)
        self._queue_log(f"命令: {safe_command_preview(command)}", False)
        self._queue_log(f"AI 配置: {ai_summary(self.ai)}", False)
        self._queue_log("", False)

    def _queue_log(self, line: str, is_error: bool) -> None:
        self.log_queue.put((line, is_error))

    def _drain_log_queue(self) -> bool:
        batch: list[tuple[str, bool]] = []
        while len(batch) < 250:
            try:
                batch.append(self.log_queue.get_nowait())
            except queue.Empty:
                break
        if not batch:
            return GLib.SOURCE_CONTINUE
        for line, is_error in batch:
            end = self.log_buffer.get_end_iter()
            if is_error:
                self.log_buffer.insert_with_tags(end, line + "\n", self.error_tag)
            else:
                self.log_buffer.insert(end, line + "\n")
            progress = parse_progress(line)
            if progress:
                self._apply_progress(progress)
        self.log_buffer.move_mark(self.log_mark, self.log_buffer.get_end_iter())
        if self.follow_logs.get_active():
            GLib.idle_add(self._scroll_log_once)
        return GLib.SOURCE_CONTINUE

    def _scroll_log_once(self) -> bool:
        self.log_view.scroll_mark_onscreen(self.log_mark)
        return GLib.SOURCE_REMOVE

    def _apply_progress(self, event: ProgressEvent) -> None:
        if event.kind == "metadata":
            self._pulse_mode = True
            self.phase_label.set_text("正在识别光盘与匹配专辑…")
        elif event.kind == "lyrics":
            self._pulse_mode = True
            self.phase_label.set_text(f"正在获取第 {event.current} 轨歌词…")
        elif event.kind == "cover":
            self._pulse_mode = True
            self.phase_label.set_text(f"正在尝试封面来源：{event.detail}")
        elif event.kind == "track_count" and event.total:
            self._pulse_mode = False
            self.progress.set_fraction(0)
        elif event.kind == "track_started" and event.current and event.total:
            self._pulse_mode = False
            self.progress.set_fraction(max(0, (event.current - 1) / event.total))
            self.phase_label.set_text(f"正在转换 {event.current}/{event.total}：{event.detail}")
        elif event.kind == "verification_started" and event.current and event.total:
            self._pulse_mode = False
            self.progress.set_fraction(min(1, (event.current - 0.5) / event.total))
            self.phase_label.set_text(f"正在无损校验 {event.current}/{event.total}…")
        elif event.kind == "track_verified" and event.current and event.total:
            self._pulse_mode = False
            self.progress.set_fraction(min(1, event.current / event.total))
            self.phase_label.set_text(f"已验证 {event.current}/{event.total} 轨")

    def _pulse_progress(self) -> bool:
        if self.runner.running and self._pulse_mode:
            self.progress.pulse()
        return GLib.SOURCE_CONTINUE

    def _update_elapsed(self) -> bool:
        if self.started_at is None:
            self.elapsed_label.set_text("00:00")
        else:
            elapsed = max(0, int(time.monotonic() - self.started_at))
            self.elapsed_label.set_text(f"{elapsed // 60:02d}:{elapsed % 60:02d}")
        return GLib.SOURCE_CONTINUE

    def _queue_release_selection(self, candidates: object) -> None:
        GLib.idle_add(self._show_release_candidates, candidates)

    def _show_release_candidates(self, candidates: object) -> bool:
        if not isinstance(candidates, list) or not all(isinstance(item, ReleaseCandidate) for item in candidates):
            self._show_error("候选专辑列表格式无效。")
            self.runner.cancel()
            return GLib.SOURCE_REMOVE
        window = Adw.Window(transient_for=self, modal=True)
        window.set_title("选择 MusicBrainz 发行版")
        window.set_default_size(720, 520)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        header = Adw.HeaderBar()
        cancel = Gtk.Button(label="取消")
        cancel.connect("clicked", lambda _button: self._cancel_release_window(window))
        header.pack_start(cancel)
        box.append(header)
        list_box = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        list_box.add_css_class("boxed-list")
        for candidate in candidates:
            details = " · ".join(value for value in (candidate.date, candidate.country, f"Disc {candidate.disc}" if candidate.disc else "") if value)
            row = Adw.ActionRow(title=f"[{candidate.index}] {candidate.artist} — {candidate.title}", subtitle=details)
            row._cdrom_candidate = candidate  # type: ignore[attr-defined]
            list_box.append(row)
        list_box.connect("row-activated", lambda _box, row: self._choose_release_row(window, row))
        scroller = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.set_child(list_box)
        scroller.set_margin_start(16)
        scroller.set_margin_end(16)
        scroller.set_margin_top(12)
        scroller.set_margin_bottom(12)
        box.append(scroller)
        choose = Gtk.Button(label="使用所选发行版")
        choose.add_css_class("suggested-action")
        choose.set_margin_start(16)
        choose.set_margin_end(16)
        choose.set_margin_bottom(16)
        choose.connect("clicked", lambda _button: self._choose_release_row(window, list_box.get_selected_row()))
        box.append(choose)
        window.set_content(box)
        window.connect("close-request", self._on_release_window_close)
        self.release_window = window
        self.phase_label.set_text("等待选择 MusicBrainz 发行版…")
        window.present()
        return GLib.SOURCE_REMOVE

    def _choose_release_row(self, window: Adw.Window, row: Gtk.ListBoxRow | None) -> None:
        if row is None:
            self._show_error("请先选择一个发行版。")
            return
        candidate = getattr(row, "_cdrom_candidate", None)
        if not isinstance(candidate, ReleaseCandidate):
            self._show_error("所选发行版无效。")
            return
        try:
            self.runner.choose_release(candidate.index)
        except RuntimeError as error:
            self._show_error(str(error))
            self.runner.cancel()
        self.release_window = None
        window.destroy()
        self.phase_label.set_text("正在使用所选版本补全专辑信息…")

    def _cancel_release_window(self, window: Adw.Window) -> None:
        self.release_window = None
        self.runner.cancel()
        window.destroy()

    def _on_release_window_close(self, _window: Adw.Window) -> bool:
        self.release_window = None
        self.runner.cancel()
        return False

    def _queue_finished(self, exit_code: int, cancelled: bool, output_directory: str | None) -> None:
        GLib.idle_add(self._finish_conversion, exit_code, cancelled, output_directory)

    def _finish_conversion(self, exit_code: int, cancelled: bool, output_directory: str | None) -> bool:
        self.started_at = None
        self._pulse_mode = False
        self.preferences_page.set_sensitive(True)
        self.ai_button.set_sensitive(True)
        self.start_button.set_sensitive(True)
        self.cancel_button.set_sensitive(False)
        if self.release_window is not None:
            self.release_window.destroy()
            self.release_window = None
        if exit_code == 0 and not cancelled:
            self.progress.set_fraction(1)
            self.status_label.set_text("转换完成")
            self.phase_label.set_text("音频、标签、封面和歌词已处理完成")
            self.last_output_directory = output_directory
            self.open_button.set_sensitive(bool(output_directory))
            self.overlay.add_toast(Adw.Toast(title="转换已完成"))
            if output_directory and self.options.open_output_on_success:
                self._open_output()
        elif cancelled:
            self.progress.set_fraction(0)
            self.status_label.set_text("已取消")
            self.phase_label.set_text("转换已安全停止")
        else:
            self.progress.set_fraction(0)
            self.status_label.set_text("转换失败")
            self.phase_label.set_text(f"转换进程退出，代码 {exit_code}")
            self._show_error("转换未成功；请查看运行日志中的错误信息。")
        if self._manual_close:
            self.destroy()
        return GLib.SOURCE_REMOVE

    def _show_ai_settings(self, _button: Gtk.Button) -> None:
        AISettingsWindow(self, dataclasses.replace(self.ai), self.remember_api_keys).present()

    def apply_ai_settings(self, ai: AIConfiguration, remember: bool) -> None:
        validate_ai_configuration(ai)
        if remember:
            self.secret_store.save_from(ai)
        elif self.remember_api_keys:
            self.secret_store.clear()
        self.ai = ai
        self.remember_api_keys = remember
        self.settings_store.save(self._sync_options(), self.ai, remember)
        self._update_ai_summary()
        self.overlay.add_toast(Adw.Toast(title="AI 设置已保存"))

    def _choose_path(self, row: Adw.EntryRow, extension: str | None, folder: bool) -> None:
        action = Gtk.FileChooserAction.SELECT_FOLDER if folder else Gtk.FileChooserAction.OPEN
        dialog = Gtk.FileChooserNative.new("选择目录" if folder else "选择文件", self, action, "选择", "取消")
        if extension and extension != "env":
            file_filter = Gtk.FileFilter()
            file_filter.set_name(f"{extension.upper()} 文件")
            file_filter.add_pattern(f"*.{extension}")
            file_filter.add_pattern(f"*.{extension.upper()}")
            dialog.set_filter(file_filter)
        dialog.connect("response", self._path_response, row)
        dialog.show()

    def _path_response(self, dialog: Gtk.FileChooserNative, response: int, row: Adw.EntryRow) -> None:
        if response == Gtk.ResponseType.ACCEPT:
            selected = dialog.get_file()
            if selected and selected.get_path():
                row.set_text(selected.get_path())
                if row is self.bin_row and not self.toc_row.get_text().strip():
                    toc = Path(selected.get_path()).with_suffix(".toc")
                    if toc.is_file():
                        self.toc_row.set_text(str(toc))
        dialog.destroy()

    def _open_output(self) -> None:
        if not self.last_output_directory:
            return
        path = Path(self.last_output_directory)
        if not path.is_dir():
            self._show_error(f"输出目录不存在：{path}")
            return
        Gio.AppInfo.launch_default_for_uri(path.resolve().as_uri(), None)

    def _copy_log(self, _button: Gtk.Button) -> None:
        text = self.log_buffer.get_text(self.log_buffer.get_start_iter(), self.log_buffer.get_end_iter(), True)
        self.get_clipboard().set(text)
        self.overlay.add_toast(Adw.Toast(title="日志已复制"))

    def _copy_preview(self, _button: Gtk.Button) -> None:
        text = self.preview_buffer.get_text(self.preview_buffer.get_start_iter(), self.preview_buffer.get_end_iter(), True)
        self.get_clipboard().set(text)
        self.overlay.add_toast(Adw.Toast(title="命令预览已复制"))

    def _clear_log(self, _button: Gtk.Button | None) -> None:
        self.log_buffer.set_text("")

    def _show_error(self, message: str) -> None:
        toast = Adw.Toast(title=message)
        toast.set_timeout(6)
        self.overlay.add_toast(toast)

    def _on_close_request(self, _window: Gtk.Window) -> bool:
        if self.runner.running:
            self._manual_close = True
            self.runner.cancel()
            self.hide()
            return True
        return False

    @staticmethod
    def _select_combo(row: Adw.ComboRow, value: str) -> None:
        values = getattr(row, "_cdrom_values", [])
        row.set_selected(values.index(value) if value in values else 0)

    @staticmethod
    def _combo_value(row: Adw.ComboRow) -> str:
        values = getattr(row, "_cdrom_values", [])
        selected = row.get_selected()
        return values[selected] if 0 <= selected < len(values) else values[0]


class AISettingsWindow(Adw.Window):
    def __init__(self, parent: MainWindow, ai: AIConfiguration, remember: bool) -> None:
        super().__init__(transient_for=parent, modal=True)
        self.parent_window = parent
        self.ai = ai
        self.set_title("AI 模型与翻译服务")
        self.set_default_size(760, 700)
        self.set_size_request(620, 520)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        header = Adw.HeaderBar()
        cancel = Gtk.Button(label="取消")
        cancel.connect("clicked", lambda _button: self.destroy())
        save = Gtk.Button(label="保存")
        save.add_css_class("suggested-action")
        save.connect("clicked", self._save)
        header.pack_start(cancel)
        header.pack_end(save)
        root.append(header)

        page = Adw.PreferencesPage()
        openai = Adw.PreferencesGroup(title="OpenAI-compatible", description="Base URL 填 API 根地址，程序自动追加 /chat/completions。")
        self.openai_key = self._password("API Key", ai.openai_api_key)
        self.openai_url = self._entry("Base URL", ai.openai_base_url)
        self.openai_model = self._entry("模型", ai.openai_model)
        self.openai_org = self._entry("Organization ID（可选）", ai.openai_org_id)
        self.openai_project = self._entry("Project ID（可选）", ai.openai_project_id)
        for row in (self.openai_key, self.openai_url, self.openai_model, self.openai_org, self.openai_project):
            openai.add(row)
        page.add(openai)

        anthropic = Adw.PreferencesGroup(title="Anthropic-compatible", description="兼容 Messages API。")
        self.anthropic_key = self._password("API Key", ai.anthropic_api_key)
        self.anthropic_url = self._entry("Base URL", ai.anthropic_base_url)
        self.anthropic_model = self._entry("模型", ai.anthropic_model)
        self.anthropic_version = self._entry("API Version", ai.anthropic_version)
        token_row = Adw.ActionRow(title="Max Tokens")
        token_adjustment = Gtk.Adjustment(value=ai.anthropic_max_tokens, lower=256, upper=32768, step_increment=256, page_increment=1024)
        self.anthropic_tokens = Gtk.SpinButton(adjustment=token_adjustment, numeric=True, valign=Gtk.Align.CENTER)
        token_row.add_suffix(self.anthropic_tokens)
        for row in (self.anthropic_key, self.anthropic_url, self.anthropic_model, self.anthropic_version, token_row):
            anthropic.add(row)
        page.add(anthropic)

        machine = Adw.PreferencesGroup(title="机器翻译", description="没有 Key 时仍会在最后依次尝试 Google GTX 与 Bing 网页翻译。")
        self.google_key = self._password("Google Cloud API Key", ai.google_api_key)
        self.google_url = self._entry("Google Base URL", ai.google_base_url)
        self.microsoft_key = self._password("Microsoft API Key", ai.microsoft_api_key)
        self.microsoft_url = self._entry("Microsoft Base URL", ai.microsoft_base_url)
        self.microsoft_region = self._entry("Microsoft Region（可选）", ai.microsoft_region)
        for row in (self.google_key, self.google_url, self.microsoft_key, self.microsoft_url, self.microsoft_region):
            machine.add(row)
        page.add(machine)

        privacy = Adw.PreferencesGroup(title="Prompt 与密钥保存")
        self.prompt = self._entry("自定义 Prompt 文件（可选）", ai.prompt_file)
        self.remember = Adw.SwitchRow(
            title="把 API Key 保存到 GNOME Keyring",
            subtitle="关闭时 Key 只保留在当前进程内；普通设置 JSON 永远不包含 Key。",
        )
        self.remember.set_active(remember)
        privacy.add(self.prompt)
        privacy.add(self.remember)
        page.add(privacy)
        root.append(page)
        self.set_content(root)

    def _save(self, _button: Gtk.Button) -> None:
        configuration = AIConfiguration(
            google_api_key=self.google_key.get_text(),
            google_base_url=self.google_url.get_text(),
            microsoft_api_key=self.microsoft_key.get_text(),
            microsoft_base_url=self.microsoft_url.get_text(),
            microsoft_region=self.microsoft_region.get_text(),
            openai_api_key=self.openai_key.get_text(),
            openai_base_url=self.openai_url.get_text(),
            openai_model=self.openai_model.get_text(),
            openai_org_id=self.openai_org.get_text(),
            openai_project_id=self.openai_project.get_text(),
            anthropic_api_key=self.anthropic_key.get_text(),
            anthropic_base_url=self.anthropic_url.get_text(),
            anthropic_model=self.anthropic_model.get_text(),
            anthropic_version=self.anthropic_version.get_text(),
            anthropic_max_tokens=self.anthropic_tokens.get_value_as_int(),
            prompt_file=self.prompt.get_text(),
        )
        try:
            self.parent_window.apply_ai_settings(configuration, self.remember.get_active())
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            self.parent_window._show_error(str(error))
            return
        self.destroy()

    @staticmethod
    def _entry(title: str, value: str) -> Adw.EntryRow:
        row = Adw.EntryRow(title=title)
        row.set_text(value)
        return row

    @staticmethod
    def _password(title: str, value: str) -> Adw.PasswordEntryRow:
        row = Adw.PasswordEntryRow(title=title)
        row.set_text(value)
        return row
