# CD-ROM Dump Tools GUI

这是 Windows 增强转换器的 C#、WinForms 图形界面。GUI 负责校验输入、组织参数、调用 PowerShell、显示实时日志并定位最终输出目录；拆轨、元数据匹配、封面、歌词、标签和文件命名仍由与仓库根脚本同源的 PowerShell 转换引擎完成。

正式发布使用 `win-x64` 自包含单文件：`bin_to_audio_windows.ps1` 作为程序集资源嵌入 EXE，运行时按内容 SHA-256 释放到 `%LOCALAPPDATA%\CdromDumpToolsGui\ConverterScripts\<SHA-256>\` 的版本化目录并校验完整性，再交给 PowerShell。用户不需要另行下载或摆放 `.ps1`，也不需要安装 .NET Runtime；被篡改的运行副本会在下次使用时按嵌入内容修复。

## 已有功能

- 选择 BIN、TOC、输出位置、FFmpeg 和 `.env` 文件；BIN/TOC 支持拖放。
- 输出无损 FLAC 或 WAV。
- 控制元数据、封面、歌词、网易云音乐和 QQ 音乐查询。
- 选择网易云/QQ 音乐标签优先级、歌词机器翻译回退顺序和 OpenAI/Anthropic API 格式。
- 常用转换、歌词/AI 和高级选项分成三个中文页签；界面显示面向用户的说明，不直接暴露 `NetEaseFirst`、`AIThenGoogle` 等内部参数值。
- 通过主界面的“配置模型与 API Key…”打开独立设置窗口：可填写 OpenAI Chat Completions 兼容接口、Anthropic Messages 兼容接口、Google Cloud Translation Basic v2 和 Microsoft Azure Translator v3 所需字段，也可选用内置 Prompt 或外部 Prompt 文件；Google GTX 与 Bing 网页端无需配置。
- 设置 MusicBrainz 发行版本序号和 User-Agent 等高级参数。
- 转换前检查路径与参数，并以参数数组启动 PowerShell，不通过 `cmd.exe` 拼接执行命令。
- 运行日志与命令预览使用独立页签；日志可复制或清空，命令可一键复制。命令自动换行、只保留纵向滚动条，API Key 不会进入预览内容。
- 实时显示在线查询阶段、曲目 `X/Y`、进度条和耗时；可停止正在运行的完整进程树。转换期间会冻结本次任务参数，避免界面预览与实际命令不一致。
- 从转换日志识别真实输出目录，成功后可直接打开。
- 保存常用输入路径、界面选项和非敏感 AI 配置到 `%LOCALAPPDATA%\CdromDumpToolsGui\settings.json`。一次性的最终输出目录不会持久化；API Key 是否保存由“记住 API Key”选项控制，保存时只写入当前 Windows 用户 DPAPI 加密后的密文。

GUI 不负责读取实体光盘。请先用根目录的 `dump_cdrom.sh` 生成 BIN/TOC，或使用已有的 `cdrdao` BIN/TOC 镜像。

## 运行要求

- Windows 10/11 x64。
- Windows PowerShell 5.1，或 PowerShell 7；单 EXE 仍会在内部调用 PowerShell，安装了 PowerShell 7 时优先使用 `pwsh.exe`。
- [FFmpeg](https://ffmpeg.org/)；可加入 `PATH`，也可在 GUI 中指定 `ffmpeg.exe`。
- BIN 文件及与其匹配的 `cdrdao` TOC 文件。
- 元数据、封面和在线歌词需要网络连接。
- 请以普通用户运行。转换不需要管理员权限；程序检测到提升后的管理员令牌时会拒绝启动，以免用户目录中的脚本、设置或工具路径被高权限进程误用。

GitHub Release 直接提供版本化的 Windows EXE：

```text
cdrom-dump-tools-版本-windows-x64.exe
```

它可以单独移动和运行，不依赖旁边的 DLL、`.runtimeconfig.json`、`.ps1` 或 .NET Runtime。PowerShell 与 FFmpeg 仍是外部运行依赖。

## 使用方法

1. 从 GitHub Release 下载 Windows x64 EXE 并直接运行。
2. 选择或拖入 `.bin`；同目录同名 `.toc` 存在时可直接使用，也可手动指定。
3. 在“转换与标签”“歌词与 AI 翻译”页签中选择所需项目；需要机器翻译回退时，可点击“配置模型与 API Key…”直接配置服务。
4. 将“自定义输出目录”留空以自动命名，或指定一个尚不存在的完整目标目录；FFmpeg、`.env`、候选序号和 User-Agent 位于“高级设置”。
5. 开始转换，在进度区查看当前在线查询阶段、曲目 `X/Y` 和耗时；“运行日志”“命令预览”页签可随时切换。转换成功后可用“打开输出目录”进入实际结果目录。

### 输出目录语义

“自动输出目录”和“指定输出目录”有意采用不同规则：

- **自动输出目录**：GUI 不向脚本传递 `-OutputDirectory`。匹配到专辑后，脚本在 BIN 旁生成 `艺术家 - 专辑 (年份) [FLAC/WAV]`；没有可靠元数据时使用 `BIN文件名-flac/wav`。同名目录存在时自动追加 `-2`、`-3`，不会覆盖原目录。
- **指定输出目录**：该路径就是最终目录，不会再按专辑名改名。为避免混入旧文件，目标目录必须尚不存在；缺失的父目录会由脚本创建。“浏览”会让你先选一个已有父目录，再生成未占用的目标名。
- GUI 在运行前显示的自动路径只是预测，日志中的 `Destination:` 也只是计划位置。元数据匹配可能改变目录名；最终成功以 `Done. Converted tracks are in:` 和退出码 `0` 为准，随后可用“打开输出目录”进入结果。

转换过程先写入同一父目录下的隐藏 `.partial` 工作目录，全部成功后再移动为最终目录。失败或取消时，日志会说明处理状态；不要把预测目录当作完成标志。

## `.env` 与 API Key 安全

在线元数据和平台已有歌词不需要 AI Key。网易云音乐、QQ 音乐和 LRCLIB 都没有中文歌词时，默认顺序为 OpenAI → Anthropic → Google Cloud → Microsoft Azure → Google GTX → Bing。前四项只在配置完整时使用；后两项无需账号或 Key，但属于可能限流、验证码或变更的非官方尽力回退。选择“仅 AI”或“关闭机器翻译”可避免调用免 Key 网页端。

日常使用可直接点击主界面的“配置模型与 API Key…”：

- **OpenAI / 兼容接口**：API Key、Base URL、模型，以及可选 Organization ID、Project ID；请求使用 Chat Completions 兼容格式，脚本会在 Base URL 后补 `/chat/completions`。
- **Anthropic / 兼容接口**：API Key、Base URL、模型、API Version 和 Max Tokens；请求使用 Messages 兼容格式，脚本会在 Base URL 后补 `/messages`。
- **Google Cloud**：Google Cloud Translation Basic v2 的 API Key 和 Base URL。
- **Microsoft Azure**：Azure AI Translator v3 的 API Key、Base URL 和可选 Region；区域或多服务资源通常要求 Region。
- **Prompt**：留空使用内置“信、达、雅”歌词翻译 Prompt；也可选择本地 UTF-8 Prompt 文件覆盖它。这里只保存文件路径，文件内容不会嵌入 EXE。

为某个服务填写 Key、模型或自定义地址后，该服务的 GUI 配置会通过**子 PowerShell 进程的环境变量**传入，并覆盖 `.env` 中的同名值；未启用服务在界面中显示的默认地址不会遮蔽 `.env`。API Key 不会成为命令行参数，也不会出现在命令预览或转换日志中。PowerShell 把配置解析到自身设置对象后会立即清除相关进程环境变量，再启动 FFmpeg 等子进程，避免把 Key 继续传给无关工具。

“记住 API Key”决定是否跨启动保存密钥：

- 勾选时，Key 使用 Windows **当前用户** DPAPI 加密，只有密文会写入 `%LOCALAPPDATA%\CdromDumpToolsGui\settings.json`；换到其他 Windows 用户时通常无法解密，GUI 会把不可读的 Key 留空并提示。
- 取消勾选时，Key 不写入设置文件，只在本次 GUI 会话内存中保留；开始转换时仍只通过子 PowerShell 的临时进程环境传递。
- Base URL、模型、Region、Organization/Project ID、API Version、Max Tokens、Prompt 文件路径等非密钥设置会按普通配置保存。
- 无论是否记住，Key 都不会写入参数、预览、日志、EXE、Git 仓库或 GitHub Release。

`.env` 仍保留为命令行和高级回退方式。从仓库的 `.env.example`，或 Release 随附的版本化 `.env.example` 资产创建本地配置：

```powershell
Copy-Item .env.example .env
notepad .env
```

然后在 GUI 中选择该 `.env`，或把文件命名为 `.env` 并放在 EXE 同目录让程序自动发现。显式选择的路径优先；已启用服务的 GUI 配置又优先于 `.env`。EXE 不会内嵌、生成或显示任何真实 API Key。

- 真实 `.env` 已被 Git 忽略，CI 和发布流程还会检查它没有被跟踪或打包。
- `.env.example` 只能保留空白占位符，禁止填写真实 Key。
- 不要把 `.env` 放进发布目录、截图、日志或问题报告；泄漏后应立即在服务商后台撤销并轮换 Key。
- 自定义 OpenAI/Anthropic/Google/Microsoft 端点必须使用 HTTPS；只有 `localhost`/loopback 本机服务允许 HTTP。Bing 的网页临时令牌仅保留在转换进程内存中，不写入设置、缓存或日志。具体变量、服务调用内容和缓存规则见仓库根目录 `README.md`。

## 构建

源码构建需要 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)。普通用户直接运行 Release EXE 时不需要 SDK 或 Runtime。

```cmd
cd gui
build.cmd
```

`build.cmd` 会先还原依赖，再构建用于开发验证的 Release 配置。主要输出位于：

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

该命令生成自包含、单文件的 `win-x64` EXE：

```text
gui\publish\win-x64\CdromDumpToolsGui.exe
```

`gui\publish\` 已被 Git 忽略，发布脚本会清理目标目录并强制检查其中只有这一个 EXE。转换脚本和 .NET 运行时均已封装在单文件中；FFmpeg 和 Windows PowerShell/PowerShell 7 不会被封装，任何 API Key 或真实 `.env` 也不会被写入 EXE。

运行不依赖桌面交互的核心检查：

```cmd
dotnet run --project gui\CdromDumpToolsGui.CoreChecks\CdromDumpToolsGui.CoreChecks.csproj -c Release
```

GitHub Actions 会在 Windows Server 2025 上使用固定的 .NET 8 SDK 还原并构建 GUI，运行包括嵌入脚本在内的核心检查，并再次发布验证“目录中恰好只有一个 EXE”。版本标签发布前会复用完整 CI、把标签版本注入 EXE，并在 Windows 上实际自检最终字节；Release 直接上传该 EXE、可选的空白 `.env.example`、Linux 脚本包、内嵌 .NET Runtime 对应的 `LICENSE`/`THIRD-PARTY-NOTICES` 和 SHA-256 清单。许可证资产不是运行依赖，真实 `.env` 永远不会上传。

## 限制

- GUI 是 Windows 转换前端，不替代 Linux 光盘读取脚本。
- 根转换器当前只接受纯 CD-DA TOC；数据轨或混合模式光盘应使用理解对应轨道格式的工具处理。
- GUI 单 EXE 包含自身所需的 .NET 运行时和 PowerShell 转换脚本，但不包含 FFmpeg、PowerShell 本身或任何在线服务凭据。
- 当前 Release EXE 未做 Authenticode 代码签名，首次下载时 Windows 可能显示 SmartScreen 提示；请从项目 Release 获取文件并用同页 `SHA256SUMS.txt` 核对哈希。
- `-ExecutionPolicy Bypass` 只处理常规 PowerShell 执行策略，不会绕过 AppLocker、WDAC、Constrained Language Mode 或杀毒软件策略；受管设备仍可能阻止转换器运行。
- 取消会终止本次转换，但外部服务已经收到的请求无法撤回；机器翻译可能产生费用。
