# CD-ROM Dump Tools GUI

`gui/` 下的 `CdromDumpToolsGui` 是一个 C# (WinForms, .NET 8) 图形界面,用于包装仓库根目录的
[`bin_to_audio_windows.ps1`](../bin_to_audio_windows.ps1) Windows 增强转换器。

转换逻辑全部仍在 PowerShell 脚本中完成,GUI 只负责收集参数、实时显示日志、取消和打开输出目录,
因此脚本的任何能力(元数据、封面、歌词、翻译回退)都会被完整保留,不必在 C# 中重复实现。

## 功能

- 选择 BIN/TOC 文件、输出目录、FFmpeg、`.env`,或直接把 `.bin`/`.toc` 拖进窗口。
- 输出格式 FLAC/WAV、国内源优先、歌词翻译回退、AI 提供方、ReleaseIndex 等选项与脚本参数一一对应。
- 转换时实时滚动显示脚本输出(中文日志按 UTF-8 解码,兼容 Windows PowerShell 5.1 和 PowerShell 7)。
- 支持取消;成功后可直接打开输出文件夹。
- 记住上次使用的路径和选项(`%LOCALAPPDATA%\CdromDumpToolsGui\settings.json`)。

## 依赖与要求

- .NET 8 SDK(构建时)。
- PowerShell 5.1(系统自带)或 PowerShell 7。有 `pwsh.exe` 时优先使用 PowerShell 7。
- 与命令行版本相同的运行时依赖:FFmpeg、网络(需要元数据/封面/歌词时)。
- GUI 通过向上查找目录自动定位 `bin_to_audio_windows.ps1`,请保持 `gui\` 目录位于仓库内。

## 构建

```cmd
cd gui
build.cmd
```

或手动发布:

```cmd
cd gui\CdromDumpToolsGui
dotnet publish -c Release -r win-x64 --self-contained false
```

产物位于 `bin\Release\net8.0-windows\win-x64\CdromDumpToolsGui.exe`。
如果需要单文件免安装版本,把 `--self-contained false` 换成 `-p:PublishSingleFile=true`(仍需要 .NET 8 桌面运行时)。

## 使用

1. 运行 `CdromDumpToolsGui.exe`。
2. 拖入 `disc.bin`(会自动补全同名 `.toc`,或手动选择)。
3. 按需调整选项,点“开始转换”。
4. 日志区显示脚本输出;转换完成后“打开输出文件夹”可用。

所有可选字段留空即使用脚本默认行为,与直接运行 PowerShell 脚本一致。
