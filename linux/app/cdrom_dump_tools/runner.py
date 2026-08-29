from __future__ import annotations

import os
import signal
import subprocess
import threading
from collections.abc import Callable

from .models import AIConfiguration, AppPaths, ConversionOptions, build_command, build_environment
from .protocol import is_release_selection_line, parse_release_candidates

LogCallback = Callable[[str, bool], None]
SelectionCallback = Callable[[object], None]
FinishCallback = Callable[[int, bool, str | None], None]


class ConversionRunner:
    def __init__(
        self,
        on_log: LogCallback,
        on_release_selection: SelectionCallback,
        on_finished: FinishCallback,
    ) -> None:
        self.on_log = on_log
        self.on_release_selection = on_release_selection
        self.on_finished = on_finished
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._cancelled = False
        self._output_directory: str | None = None

    @property
    def running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def start(self, options: ConversionOptions, ai: AIConfiguration, paths: AppPaths) -> list[str]:
        command = build_command(options, paths, require_files=True)
        environment = build_environment(options, ai, paths)
        process = subprocess.Popen(
            command,
            cwd=paths.converter.parent,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
        )
        with self._lock:
            if self._process is not None:
                process.terminate()
                raise RuntimeError("已有转换正在运行。")
            self._process = process
            self._cancelled = False
            self._output_directory = None

        stdout_thread = threading.Thread(target=self._read_stream, args=(process.stdout, False), daemon=True)
        stderr_thread = threading.Thread(target=self._read_stream, args=(process.stderr, True), daemon=True)
        stdout_thread.start()
        stderr_thread.start()
        threading.Thread(
            target=self._wait,
            args=(process, stdout_thread, stderr_thread),
            daemon=True,
        ).start()
        return command

    def choose_release(self, index: int) -> None:
        with self._lock:
            process = self._process
            if process is None or process.poll() is not None or process.stdin is None or self._cancelled:
                raise RuntimeError("转换进程已经退出，无法提交候选版本。")
            stream = process.stdin
        try:
            stream.write(f"{index}\n")
            stream.flush()
        except (BrokenPipeError, OSError, ValueError) as error:
            raise RuntimeError("转换进程已结束，候选发行版未能提交。") from error
        self.on_log(f"已选择 MusicBrainz 候选 [{index}]，继续转换。", False)

    def cancel(self) -> None:
        with self._lock:
            process = self._process
            if process is None or process.poll() is not None:
                return
            self._cancelled = True
            try:
                if process.stdin is not None:
                    process.stdin.close()
            except OSError:
                pass
            pid = process.pid
        self.on_log("已请求取消，正在终止 PowerShell 与 FFmpeg 进程组。", True)
        try:
            os.killpg(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            try:
                process.terminate()
            except ProcessLookupError:
                return
        threading.Timer(2.0, self._force_kill, args=(process,)).start()

    def _read_stream(self, stream: object, is_error: bool) -> None:
        if stream is None:
            return
        try:
            for raw_line in stream:
                line = raw_line.rstrip("\r\n")
                if not is_error and is_release_selection_line(line):
                    try:
                        self.on_release_selection(parse_release_candidates(line))
                    except ValueError as error:
                        self.on_log(f"错误：{error}", True)
                        self.cancel()
                    continue
                marker = "Done. Converted tracks are in:"
                if not is_error and line.startswith(marker):
                    output = line[len(marker) :].strip()
                    if output:
                        with self._lock:
                            self._output_directory = output
                self.on_log(line, is_error)
        except (OSError, ValueError) as error:
            self.on_log(f"日志读取失败：{error}", True)

    def _wait(
        self,
        process: subprocess.Popen[str],
        stdout_thread: threading.Thread,
        stderr_thread: threading.Thread,
    ) -> None:
        exit_code = process.wait()
        stdout_thread.join(timeout=5)
        stderr_thread.join(timeout=5)
        with self._lock:
            if self._process is not process:
                return
            cancelled = self._cancelled
            output_directory = self._output_directory
            self._process = None
            self._cancelled = False
            self._output_directory = None
        self.on_finished(exit_code, cancelled, output_directory)

    def _force_kill(self, process: subprocess.Popen[str]) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                process.kill()
            except ProcessLookupError:
                pass
