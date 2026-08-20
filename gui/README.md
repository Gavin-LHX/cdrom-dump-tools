# CD-ROM Dump Tools GUI

这是 `bin_to_audio_windows.ps1` 的 Windows 图形界面，使用 C#、WinForms 和 .NET 8 构建。GUI 负责校验输入、组织参数、启动转换器、显示实时日志并定位最终输出目录；拆轨、元数据匹配、封面、歌词、标签和文件命名仍由仓库根目录的 PowerShell 脚本完成。

## 已有功能

- 选择 BIN、TOC、输出位置、FFmpeg 和 `.env` 文件；BIN/TOC 支持拖放。
- 输出无损 FLAC 或 WAV。
- 控制元数据、封面、歌词、网易云音乐和 QQ 音乐查询。
- 选择网易云/QQ 音乐标签优先级、歌词机器翻译回退顺序和 OpenAI/Anthropic API 格式。
- 设置 MusicBrainz 发行版本序号和 User-Agent 等高级参数。
- 转换前检查路径与参数，并以参数数组启动 PowerShell，不通过 `cmd.exe` 拼接执行命令。
- 实时显示标准输出和错误输出；可取消正在运行的转换。
- 从转换日志识别真实输出目录，成功后可直接打开。
- 保存常用输入路径和界面选项到 `%LOCALAPPDATA%\CdromDumpToolsGui\settings.json`。一次性的最终输出目录不会持久化；设置文件只记录 `.env` 的路径，不保存 API Key 内容。

GUI 不负责读取实体光盘。请先用根目录的 `dump_cdrom.sh` 生成 BIN/TOC，或使用已有的 `cdrdao` BIN/TOC 镜像。

## 运行要求

- Windows 10/11 x64。
- [.NET 8 Desktop Runtime x64](https://dotnet.microsoft.com/download/dotnet/8.0)。GitHub Release 和 `publish.cmd` 生成的是 framework-dependent 版本，不会捆绑整个 .NET 运行时。
- Windows PowerShell 5.1，或 PowerShell 7；安装了 PowerShell 7 时优先使用 `pwsh.exe`。
- [FFmpeg](https://ffmpeg.org/)；可加入 `PATH`，也可在 GUI 中指定 `ffmpeg.exe`。
- BIN 文件及与其匹配的 `cdrdao` TOC 文件。
- 元数据、封面和在线歌词需要网络连接。

GUI 启动时会从自身目录逐级向上查找 `bin_to_audio_windows.ps1`。GitHub Release 的 Windows ZIP 已按下列结构放置文件，请不要只移动其中的 EXE：

```text
cdrom-dump-tools-版本/
├── bin_to_audio_windows.ps1
├── bin_to_audio_windows.cmd
├── .env.example
├── README.md
└── gui/
    ├── CdromDumpToolsGui.exe
    ├── CdromDumpToolsGui.dll
    ├── CdromDumpToolsGui.deps.json
    ├── CdromDumpToolsGui.runtimeconfig.json
    └── README.md
```

## 使用方法

1. 解压 Windows 发布包并运行 `gui\CdromDumpToolsGui.exe`。
2. 选择或拖入 `.bin`；同目录同名 `.toc` 存在时可直接使用，也可手动指定。
3. 选择 FLAC/WAV 和所需的元数据、封面、歌词选项。
4. 将“最终输出目录”留空以自动命名，或指定一个尚不存在的完整目标目录。
5. 开始转换，在日志区确认匹配来源和进度。转换成功后可用“打开输出目录”进入实际结果目录。

### 输出目录语义

“自动输出目录”和“指定输出目录”有意采用不同规则：

- **自动输出目录**：GUI 不向脚本传递 `-OutputDirectory`。匹配到专辑后，脚本在 BIN 旁生成 `艺术家 - 专辑 (年份) [FLAC/WAV]`；没有可靠元数据时使用 `BIN文件名-flac/wav`。同名目录存在时自动追加 `-2`、`-3`，不会覆盖原目录。
- **指定输出目录**：该路径就是最终目录，不会再按专辑名改名。为避免混入旧文件，目标目录必须尚不存在；缺失的父目录会由脚本创建。“浏览”会让你先选一个已有父目录，再生成未占用的目标名。
- GUI 在运行前显示的自动路径只是预测，日志中的 `Destination:` 也只是计划位置。元数据匹配可能改变目录名；最终成功以 `Done. Converted tracks are in:` 和退出码 `0` 为准，随后可用“打开输出目录”进入结果。

转换过程先写入同一父目录下的隐藏 `.partial` 工作目录，全部成功后再移动为最终目录。失败或取消时，日志会说明处理状态；不要把预测目录当作完成标志。

## `.env` 与 API Key 安全

在线元数据和平台已有歌词不需要 AI Key。只有在网易云音乐、QQ 音乐和 LRCLIB 都没有中文歌词，并启用 AI/Google 翻译回退时，才需要相应配置。

从根目录模板创建本地配置：

```powershell
Copy-Item .env.example .env
notepad .env
```

然后在 GUI 中选择该 `.env`，或把它放在 `bin_to_audio_windows.ps1` 旁边使用默认位置。

- 真实 `.env` 已被 Git 忽略，CI 和发布流程还会检查它没有被跟踪或打包。
- `.env.example` 只能保留空白占位符，禁止填写真实 Key。
- GUI 设置只保存 `.env` 文件路径，不读取或复制 Key 到 `settings.json`。
- 不要把 `.env` 放进发布目录、截图、日志或问题报告；泄漏后应立即在服务商后台撤销并轮换 Key。
- 自定义 OpenAI/Anthropic 兼容端点时优先使用 HTTPS。具体变量、服务调用内容和缓存规则见仓库根目录 `README.md`。

## 构建

构建需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)，不是只有 Desktop Runtime。

```cmd
cd gui
build.cmd
```

`build.cmd` 会先还原依赖，再构建 Release 配置。主要输出位于：

```text
gui\CdromDumpToolsGui\bin\Release\net8.0-windows\
```

也可直接执行：

```cmd
dotnet restore gui\CdromDumpToolsGui\CdromDumpToolsGui.csproj
dotnet build gui\CdromDumpToolsGui\CdromDumpToolsGui.csproj -c Release --no-restore
```

## 本地发布

```cmd
cd gui
publish.cmd
```

该命令生成 framework-dependent `win-x64` 文件：

```text
gui\publish\win-x64\
```

`gui\publish\` 已被 Git 忽略。这个目录只含 GUI 运行文件；测试时仍需让它能够向上找到根 PowerShell 脚本，或按上面的发布包结构把 GUI 放入脚本旁的 `gui\` 子目录。

运行不依赖桌面交互的核心检查：

```cmd
dotnet run --project gui\CdromDumpToolsGui.CoreChecks\CdromDumpToolsGui.CoreChecks.csproj -c Release
```

GitHub Actions 会在 Windows Server 2025 上使用固定的 .NET 8 SDK 还原并构建 GUI，同时运行该核心检查项目；版本标签发布前还会复用完整 CI，并把标签版本注入 GUI。Release 中的 Windows ZIP 会包含 GUI、根 PowerShell 启动文件、根 README 和安全的 `.env.example`，绝不会包含真实 `.env`。

## 限制

- GUI 是 Windows 转换前端，不替代 Linux 光盘读取脚本。
- 根转换器当前只接受纯 CD-DA TOC；数据轨或混合模式光盘应使用理解对应轨道格式的工具处理。
- GUI 不包含 FFmpeg、.NET 运行时或任何在线服务凭据。
- 取消会终止本次转换，但外部服务已经收到的请求无法撤回；机器翻译可能产生费用。
