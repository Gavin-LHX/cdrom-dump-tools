# CD-ROM Dump Tools

一套用于完整读取 CD、保存 BIN/TOC 镜像，以及将 CD-DA 音轨转换为 FLAC/WAV 的脚本。

项目同时提供 Linux 服务器端的光盘镜像脚本、Windows 本地增强转换脚本和 .NET 8 WinForms 图形界面。Windows 版本能够自动查询专辑与曲目信息、重命名文件、写入封面和标签，并获取同步歌词。

## 文件说明

| 文件 | 平台 | 用途 |
| --- | --- | --- |
| `dump_cdrom.sh` | Linux | 从实体光驱读取完整 CD，生成 BIN/TOC、校验和及读取信息 |
| `bin_to_audio.sh` | Linux | 将纯 CD-DA 的 BIN/TOC 拆分为基础 FLAC/WAV 音轨 |
| `bin_to_audio_windows.ps1` | Windows | 增强转换器：拆轨、元数据、年份/流派比对、封面、歌词和自动命名 |
| `bin_to_audio_windows.cmd` | Windows | 拖放式启动器，默认调用 PowerShell 脚本转换为 FLAC |
| [`gui/`](gui/README.md) | Windows | .NET 8 WinForms 前端：配置转换参数、显示实时日志、取消任务并打开最终输出目录 |
| `.env.example` | Windows | 机器翻译回退的高级/命令行配置模板；GUI 也可直接填写，真实 `.env` 不应提交或分享 |

## 功能概览

### Linux 光盘镜像

- 使用 `cdrdao read-cd --read-raw` 保存原始扇区和 TOC。
- 音频读取使用 `--paranoia-mode 3`。
- 可选 `--verify-passes 2`：默认以 4× 独立读取两遍，同时比较 BIN 和 TOC 的 SHA-256。
- 双遍一致时只保留一份镜像；不一致时保留两次结果、两份读取日志并以状态码 2 警告。
- 每遍的 Q 子通道 CRC 计数会写入 `verification-report.txt`，但不会单凭计数覆盖镜像。
- 支持纯音频、数据和混合模式 CD 的 BIN/TOC 归档。
- 生成 `SHA256SUMS`、`disc-info.txt` 和 `dump-metadata.txt`。
- 根据 MusicBrainz Disc ID 查询专辑信息。
- 默认目录名：`艺术家 - 专辑 (年份) [BIN-TOC]`。
- 元数据回退：30 天缓存 → MusicBrainz 主站 → MusicBrainz 镜像 → 过期缓存 → 时间戳目录。
- 查询失败不会导致光盘读取失败。
- 同名目录自动追加 `-2`、`-3`，不会覆盖已有归档。
- 在临时目录中读取，全部成功后才原子移动为最终目录。

### Windows 增强转换

- 解析 `cdrdao` TOC，按字节边界拆分 CD-DA 音轨。
- 使用 FFmpeg 输出无损 FLAC 或 WAV。
- 自动计算 MusicBrainz Disc ID 并匹配正确发行版本。
- 自动写入曲名、歌手、专辑、年份、日期、流派、ISRC、条码和 MusicBrainz ID。
- 光盘身份识别固定优先使用 MusicBrainz Disc ID/TOC；若查不到，才会读取同目录可信 JSON、TOC CD-TEXT 或 `艺术家 - 专辑 (年份)` 目录名作为搜索提示，并且仍须由国内平台候选通过轨数/时长校验后才接受。
- 识别出发行版后，曲名、艺人和专辑等展示字段默认按“选定的国内主源（网易云优先，可切换为 QQ）→ MusicBrainz”填充；日期和流派优先采用已验证国内源，缺失时再由 MusicBrainz、Apple、Wikidata 等证据补全和比对。
- 网易云和 QQ 音乐候选都必须通过专辑名、艺人、曲目数及整张专辑逐轨时长校验；高置信度匹配才会覆盖曲名、艺人、专辑、日期、文件名和封面，数字版与实体 CD 轨数不同时不会误套。
- 若实体 CD 比国内数字版多附赠曲，脚本会在保留 MusicBrainz 实体专辑身份的前提下逐轨搜索；单曲只有同时通过标题版本、艺人、专辑和不超过 3 秒的时长校验才写入国内歌曲 ID/规范曲名。逐轨结果不会冒充整专匹配，也不会改变专辑、日期或封面。
- 网易云匹配写入 `NETEASECLOUDMUSIC_ALBUMID`、`NETEASECLOUDMUSIC_TRACKID`；QQ 音乐匹配写入 `QQMUSIC_ALBUMMID`、`QQMUSIC_TRACKMID`。JSON 同时保留 MusicBrainz 原始曲名及两个国内平台的 ID。
- 国内源均失败、被风控或得分不足时自动保留 MusicBrainz 标题；Apple 与 Wikidata 继续补充年份和流派，Apple、Deezer、Wikidata 等继续参与后续封面回退。
- 流派标签优先采用英文，并统一常见大小写与本地化名称（例如 `テクノ` → `Techno`、`アニメ` → `Anime`、`j-pop` → `J-Pop`）；同一专辑的全部曲目写入相同流派。
- 封面优先复用通过验证的本地缓存；没有有效缓存时，按“选中的国内主源 → 另一个已验证国内源 → Cover Art Archive 精确发行版 → Cover Art Archive 发行组 → Apple iTunes Search → Deezer → Wikidata/Wikimedia Commons”顺序自动回退。
- Windows PowerShell 5.1 下使用 .NET 二进制流保存封面，兼容含中文、日文等非 ASCII 字符的输出路径；本地写盘错误不会再被误判为网络故障反复等待。
- Apple 和 Deezer 候选会按专辑名/别名、艺人、轨数及年份交叉评分，低置信度图片不会写入；下载内容还会经 FFmpeg 解码验证并统一转换为 JPEG。
- 生成 `cover.jpg`、`folder.jpg`，并把封面嵌入 FLAC；实际采用的来源、URL、匹配依据和置信度记录在 `metadata.json`，同时保留兼容旧版的 `musicbrainz-metadata.json`。
- 自动命名为 `01 - 歌曲名.flac`。
- 默认目录名：`艺术家 - 专辑 (年份) [FLAC/WAV]`。
- 本地 `.lrc/.txt` 仍作为用户手动覆盖；在线歌词固定按“网易云音乐 → QQ 音乐 → LRCLIB”查询。当前来源没有中文歌词或译文时会继续下一来源：QQ 有中译时可优先于网易云外文原词，LRCLIB 有中文/双语正文时也可优先于两个国内源的外文原词；三者都只有外文时，保留顺序中最早的有效原词用于机器翻译。
- 网易云歌词同时请求原文、中文翻译和可用的罗马音；QQ 音乐也请求原文、中文翻译及罗马音，并在接口返回可直接解码的内容时保留。翻译会与原文合并为双语 LRC/SRT，但不会把两个不同来源的歌词强行拼接。
- 完成网易云、QQ 音乐和 LRCLIB 的歌词搜索后，如果最终选中的有效歌词仍没有中文，并且 GUI、进程环境或 `.env` 中配置了可用 API，默认依次尝试配置完整的 OpenAI-compatible、Anthropic-compatible AI；AI 均失败或不可用时才回退 Google Cloud Translation。已有中文、纯音乐、没有有效歌词或没有完整 API 配置时不会调用。
- AI 翻译同时兼容 OpenAI-compatible Chat Completions 与 Anthropic-compatible Messages 格式。内置“信、达、雅”Prompt 要求忠实原意、自然通顺、保留意象风格，并严格保持逐行 ID、顺序和数量；LRC 时间戳始终在本地重建。
- 只有署名、作曲/编曲信息、`暂无歌词` 或纯音乐占位文字的响应会被判定为无实质歌词并立即回退，QQ 返回的无歌词状态也不会当作网络故障反复重试。
- LRCLIB 响应始终从原始字节按 UTF-8 解码，兼容 Windows PowerShell 5.1 的非 ASCII JSON。
- 严格字段搜索无结果或置信度不足时，自动使用“歌手＋曲名”的宽泛搜索回退。
- 根据 `Instrumental`、`Off Vocal`、`Karaoke` 等标题标记识别纯音乐，不再计入歌词缺失。
- 歌词结果区分 `found`、`instrumental`、`not_found`、`low_confidence` 和 `network_error`。
- 同步歌词保存为同名 `.lrc`，纯文本歌词保存为 `.txt`。
- 同步 `.lrc` 会同时转换为 UTF-8 SRT，集中保存到输出目录的 `Subtitles/` 文件夹；文件名与音频一致，可供 VLC 等播放器加载。
- FLAC 写入 `LYRICS`、`SYNCEDLYRICS`、`LYRICS_SOURCE`，并分别保留 `LYRICS_ORIGINAL`、`LYRICS_TRANSLATION`、`LYRICS_ROMANIZED` 及对应同步标签。
- 纯音乐会标记为 `instrumental`，不会写入伪歌词。
- 输出 `metadata.json`、兼容旧版的 `musicbrainz-metadata.json`、`lyrics-metadata.json`、播放列表和 SHA-256 校验和。
- MusicBrainz 请求全局限制为最多每 1.1 秒一次；遇到 429、503 或临时 5xx 时遵循 `Retry-After` 或指数退避，最多重试 5 次后再使用镜像/缓存。
- 在线服务不可用时使用 30 天缓存、多源回退或降级转换，不中断音频处理。
- 网易云、QQ 音乐和 LRCLIB 歌词使用独立缓存命名空间；接口临时不可用时会依次切换备用域名、退避重试、使用缓存或进入下一来源。
- AI/Google 译文按服务、模型、Prompt 版本和原歌词哈希保存在本机独立缓存中，重复转换相同内容时可避免不必要的 API 调用和费用。

### Windows 图形界面

[`gui/`](gui/README.md) 提供重新设计的 .NET 8 WinForms 前端。正式发布的自包含单 EXE 嵌入与根脚本同源的 PowerShell 转换引擎，但不重新实现其业务逻辑。常用转换、歌词/AI 和高级设置采用分组页签，选项使用中文说明和正向功能开关；主界面的“配置模型与 API Key…”可直接配置 OpenAI Chat Completions 兼容接口、Anthropic Messages 兼容接口、Google Cloud Translation Basic v2 和可选 Prompt 文件。运行时会显示在线查询阶段、曲目 `X/Y`、进度和耗时，并从日志识别经专辑元数据命名后的实际输出目录。

运行日志和命令预览位于独立页签；日志可复制或清空，命令可一键复制。命令自动换行且没有横向滚动条，也不会显示 API Key。为已启用服务填写的 GUI 翻译配置通过子 PowerShell 进程环境覆盖 `.env`，未启用服务的界面默认值不会遮蔽 `.env`；脚本解析后会先清除这些环境变量，再启动 FFmpeg 等子进程。Key 可选择仅保留在当前会话内存，或使用 Windows 当前用户 DPAPI 加密后保存到 `%LOCALAPPDATA%\CdromDumpToolsGui\settings.json`；明文不会进入参数、预览、日志、EXE 或 Release。

在仓库中构建或发布 GUI：

```cmd
cd gui
build.cmd
publish.cmd
```

`build.cmd` 需要 .NET 8 SDK；`publish.cmd` 在 `gui\publish\win-x64\CdromDumpToolsGui.exe` 生成自包含单文件。该 EXE 不依赖外部 `.ps1` 或 .NET Runtime，可以单独移动；运行时仍会调用系统 PowerShell，并继续要求外部 FFmpeg。EXE 不内嵌 API Key 或真实 `.env`。完整依赖、输出目录语义、GUI/`.env` 密钥安全要求和发布方式见 [GUI 中文说明](gui/README.md)。

GUI 应以普通用户身份运行；它会拒绝提升后的管理员令牌。公开 Release EXE 当前未做 Authenticode 签名，Windows 可能显示 SmartScreen 提示，请从项目 Release 下载并使用同页 `SHA256SUMS.txt` 校验文件。

## Linux：安装与读取 CD

### 依赖

Debian/Ubuntu：

```bash
sudo apt update
sudo apt install cdrdao curl python3 coreutils util-linux
```

### 安装

```bash
sudo install -o root -g root -m 0755 dump_cdrom.sh /dump_cdrom.sh
```

默认光驱是 `/dev/cdrom`，默认输出根目录是 `/mnt/hdd2/cdrom-dumps`。均可通过参数或环境变量修改。

### 使用

```bash
sudo /dump_cdrom.sh
```

建议为状态不佳的光盘降低读取速度：

```bash
sudo /dump_cdrom.sh --speed 4
sudo /dump_cdrom.sh --speed 2
```

完整读取两遍并比较 BIN/TOC 哈希：

```bash
# 未指定 --speed 时，两遍默认均为 4×
sudo /dump_cdrom.sh --verify-passes 2

# 两遍均使用更低的 2×
sudo /dump_cdrom.sh --verify-passes 2 --speed 2

# 单独修改双遍校验的默认限速
sudo /dump_cdrom.sh --verify-passes 2 --verify-speed 2
```

如果同时指定高于校验速度的 `--speed`，首遍使用明确指定的速度，第二遍回落到校验速度；如果 `--speed` 更低，两遍都使用更低速度。两遍哈希一致时，脚本保留首遍作为正式 BIN/TOC，并保留两份 `cdrdao` 日志和校验报告。哈希不一致时，首遍仍使用标准文件名，第二遍保存在 `verification-pass-2/`；脚本不会自动弹盘，并以状态码 2 结束。

其他示例：

```bash
# 指定光驱和输出目录
sudo /dump_cdrom.sh --device /dev/sr0 --output-dir /data/cd-images

# 手动指定目录/镜像名称；手动名称优先于在线专辑名称
sudo /dump_cdrom.sh --name my-disc

# 禁用在线元数据查询
sudo /dump_cdrom.sh --no-metadata

# 成功后弹出光盘
sudo /dump_cdrom.sh --eject

# 只检查参数和光驱状态
sudo /dump_cdrom.sh --dry-run
```

也可以使用环境变量：

```bash
export CDROM_DEVICE=/dev/sr0
export CDROM_DUMP_DIR=/data/cd-images
export CDROM_NO_METADATA=1
export CDROM_VERIFY_PASSES=2
export CDROM_VERIFY_SPEED=4
```

## Linux：将 BIN/TOC 转换为音轨

### 依赖

```bash
sudo apt install sox flac coreutils
```

### 使用

```bash
chmod +x bin_to_audio.sh

# 默认转换为 FLAC，并自动寻找同名 TOC
./bin_to_audio.sh /path/to/disc.bin

# 转换为 WAV
./bin_to_audio.sh --format wav /path/to/disc.bin

# 明确指定 TOC 和输出目录
./bin_to_audio.sh \
  --toc /path/to/disc.toc \
  --output-dir /path/to/output \
  /path/to/disc.bin

# 只解析和检查，不生成文件
./bin_to_audio.sh --dry-run /path/to/disc.bin
```

Linux 转换器是基础离线版本，只写入轨号和 TOC 中已有的 ISRC。需要自动专辑信息、封面、歌词及曲名重命名时，使用 Windows 增强版本。

## Windows：增强转换

### 依赖

- Windows PowerShell 5.1 或 PowerShell 7
- [FFmpeg](https://ffmpeg.org/)
- BIN 文件和匹配的 `cdrdao` TOC 文件
- 元数据、封面和歌词功能需要网络连接

脚本会优先使用 `PATH` 中的 `ffmpeg.exe`，也可通过 `-FfmpegPath` 明确指定。

MusicBrainz 要求客户端不超过每秒一次请求。脚本会在所有 MusicBrainz 主站请求之间统一等待 1.1 秒，并缓存结果；HTTP 503 既可能是当前 IP/客户端速率过高，也可能是服务整体繁忙，因此脚本会自动退避重试，不会立即丢弃专辑信息。网易云音乐、QQ 音乐和 Apple Search API 也有独立节流、响应校验、重试和 30 天缓存。

### 拖放使用

将 `.bin` 文件拖到 `bin_to_audio_windows.cmd` 上，脚本会查找同目录同名 `.toc`，默认输出 FLAC。

转换成功后，脚本在交互式且标准输入未重定向时默认停留在 `Press any key to exit...`，按任意键才会关闭，因此可以先查看元数据、封面、歌词和输出目录等处理结果。直接从 PowerShell 运行时行为相同；批处理或自动化任务可添加 `-NoPause` 跳过等待。

### PowerShell 使用

```powershell
# 默认 FLAC
.\bin_to_audio_windows.ps1 -BinPath 'D:\CD\disc.bin'

# WAV
.\bin_to_audio_windows.ps1 -BinPath 'D:\CD\disc.bin' -Format wav

# 指定 TOC、输出目录和 FFmpeg
.\bin_to_audio_windows.ps1 `
  -BinPath 'D:\CD\disc.bin' `
  -TocPath 'D:\CD\disc.toc' `
  -OutputDirectory 'D:\Music\My Album' `
  -FfmpegPath 'D:\Apps\FFmpeg\bin\ffmpeg.exe'

# 网易云/QQ/LRCLIB 均没有中文时，先用 OpenAI/Anthropic 格式的 AI，AI 不可用再用 Google
.\bin_to_audio_windows.ps1 `
  -BinPath 'D:\CD\disc.bin' `
  -LyricsTranslationFallback AIThenGoogle `
  -AiTranslationProvider Auto

# 使用其他位置的配置文件，并强制采用 Anthropic-compatible Messages 格式
.\bin_to_audio_windows.ps1 `
  -BinPath 'D:\CD\disc.bin' `
  -EnvPath 'D:\Secrets\cdrom-dump-tools.env' `
  -LyricsTranslationFallback AI `
  -AiTranslationProvider Anthropic
```

可选开关：

```powershell
# 不查询在线元数据
-NoMetadata

# 不下载或嵌入封面
-NoCover

# 不查询、保存或嵌入歌词
-NoLyrics

# 不使用网易云音乐元数据和歌词；仍会尝试 QQ 音乐及后续源
-NoNetEase

# 不使用 QQ 音乐元数据和歌词
-NoQQMusic

# 转换完成后不等待按键，适合批处理或自动化；默认会等待按任意键退出
-NoPause

# 中文歌词机器翻译回退：Auto、None、Google、AI、GoogleThenAI 或 AIThenGoogle
# Auto 读取 .env 的 LYRICS_TRANSLATION_FALLBACK；模板默认 AIThenGoogle
-LyricsTranslationFallback AIThenGoogle

# AI API 格式：Auto、OpenAI 或 Anthropic；Auto 依次尝试已完整配置的 OpenAI、Anthropic
-AiTranslationProvider Auto

# 指定其他 .env 文件；相对路径以当前工作目录为准。未指定时读取脚本旁的 .env
-EnvPath 'D:\Secrets\cdrom-dump-tools.env'

# 标签和封面的两个国内源均匹配时优先使用 QQ 音乐；默认值为 NetEaseFirst，不改变歌词的中文翻译优先规则
-DomesticSourcePriority QQMusicFirst

# MusicBrainz 返回多个发行版本时选择指定序号
-ReleaseIndex 2

# 自定义符合 MusicBrainz 要求的客户端 User-Agent
-MusicBrainzUserAgent 'MyCdRipper/1.0 (contact@example.com)'
```

### 中文歌词机器翻译回退

机器翻译默认是条件式回退，不会替代平台已有的中文歌词或译文。脚本先按网易云 → QQ 音乐 → LRCLIB 获取结果；网易云或 QQ 只有外文原词时仍会继续查后续来源。三者都没有中文时，才把顺序中最早的有效非纯音乐原词交给 AI → Google 回退链。任何翻译接口失败都只会保留原歌词并继续转换音频。

GUI 用户可点击主界面的“配置模型与 API Key…”直接设置：OpenAI / 兼容接口提供 API Key、Base URL、模型和可选 Organization/Project ID，使用 Chat Completions 兼容格式；Anthropic / 兼容接口提供 API Key、Base URL、模型、API Version 和 Max Tokens，使用 Messages 兼容格式；Google 页提供 Cloud Translation Basic v2 的 API Key 与 Base URL。Prompt 留空时使用内置“信、达、雅”版本，也可选择本地 UTF-8 Prompt 文件覆盖。

为某个服务填写 Key、模型或自定义地址后，该服务的 GUI 字段不会拼进命令行，而是仅注入本次子 PowerShell 进程环境，并优先于 `.env` 同名值；未启用服务在界面中显示的默认值不会遮蔽 `.env`。PowerShell 将这些值解析到设置对象后立即清除相关进程环境变量，然后才会启动 FFmpeg 等子进程。API Key 不会出现在参数、命令预览、转换日志、EXE 或 GitHub Release 中。

在“配置模型与 API Key…”中勾选“记住 API Key”时，Key 会用 Windows 当前用户 DPAPI 加密，`%LOCALAPPDATA%\CdromDumpToolsGui\settings.json` 只保存密文；不同 Windows 用户通常无法解密。取消勾选时不持久化 Key，只在当前 GUI 会话内存中保留，并在转换时通过上述临时子进程环境传递。Base URL、模型、Organization/Project ID、API Version、Max Tokens 和 Prompt 文件路径属于非密钥设置，会正常保存。

`.env` 仍是命令行和高级回退配置。GitHub Release 资产和仓库都提供空白 `.env.example`；命令行脚本首次使用时可在 `bin_to_audio_windows.ps1` 所在目录执行：

```powershell
Copy-Item .env.example .env
notepad .env
```

`.env` 已被 Git 忽略，不会进入发布归档。也可以不创建脚本旁的 `.env`，改用 `-EnvPath` 指向其他文件；GUI 还会自动发现 EXE 同目录的 `.env`。命令行的 `-LyricsTranslationFallback`、`-AiTranslationProvider` 优先于 `.env`；其他配置也可由同名进程环境变量提供，进程环境变量优先于 `.env`。

翻译模式：

- `None`：关闭 Google/AI 翻译。
- `Google`：只使用 Google Cloud Translation Basic v2。
- `AI`：只使用已配置的 AI API 格式。
- `GoogleThenAI`：Google 失败或不可用时再尝试 AI。
- `AIThenGoogle`：AI 失败或不可用时再尝试 Google。
- 参数值 `Auto`：读取 `LYRICS_TRANSLATION_FALLBACK`；若仍为 `Auto` 或未配置，则采用 `AIThenGoogle`，但只保留真正配置完整的服务。OpenAI、Anthropic 和 Google 都配置完整时，实际顺序为 OpenAI → Anthropic → Google。

`.env` 支持以下变量：

| 变量 | 说明 |
| --- | --- |
| `LYRICS_TRANSLATION_FALLBACK` | `None`、`Google`、`AI`、`GoogleThenAI` 或 `AIThenGoogle` |
| `AI_TRANSLATION_PROVIDER` | `Auto`、`OpenAI` 或 `Anthropic`；`Auto` 按 OpenAI → Anthropic 尝试已完整配置的格式 |
| `GOOGLE_TRANSLATE_API_KEY` | Google Cloud Translation Basic v2 API Key |
| `GOOGLE_TRANSLATE_BASE_URL` | Google 翻译端点；通常保留模板默认值 |
| `OPENAI_API_KEY` | OpenAI 或兼容网关的 API Key |
| `OPENAI_BASE_URL` | OpenAI-compatible API 根地址（如 `https://api.openai.com/v1`）；不要包含最终 `/chat/completions`、查询串或凭据 |
| `OPENAI_MODEL` | Chat Completions 使用的模型名；与 Key 一样为必填项 |
| `OPENAI_ORG_ID`、`OPENAI_PROJECT_ID` | 可选的 OpenAI 组织和项目头 |
| `ANTHROPIC_API_KEY` | Anthropic 或兼容网关的 API Key |
| `ANTHROPIC_BASE_URL` | Anthropic-compatible API 根地址（如 `https://api.anthropic.com/v1`）；不要包含最终 `/messages`、查询串或凭据 |
| `ANTHROPIC_MODEL` | Messages API 使用的模型名；与 Key 一样为必填项 |
| `ANTHROPIC_VERSION` | Anthropic API 版本头，模板默认 `2023-06-01` |
| `ANTHROPIC_MAX_TOKENS` | 单次 AI 译文的最大输出 Token，模板默认 `4096` |
| `AI_TRANSLATION_PROMPT_FILE` | 可选的 UTF-8 自定义系统 Prompt；相对路径以 `.env` 所在目录为准 |

内置 AI Prompt 以“信”为最高优先级，再追求“达”和“雅”：不得为了押韵或文采改变事实、否定关系、人物、时态、视角和语气；同时要求译文自然简洁，尽量保留意象、节奏、俚语和双关。它把歌词与专辑信息明确视为数据而不是指令，只接受严格 JSON，并要求返回与原文完全一致的逐行 ID、顺序和数量。脚本据此在本地恢复 LRC 时间戳和生成双语 SRT。需要自行调整翻译风格时，可通过 `AI_TRANSLATION_PROMPT_FILE` 覆盖内置 Prompt。

机器翻译会把待翻译的歌词行发送给所选 Google、OpenAI-compatible 或 Anthropic-compatible 服务；AI 服务还会收到用于消歧的曲名、艺人和专辑名，Google 只接收歌词行。脚本不会向这些服务上传 BIN、FLAC、WAV 或任何音频内容。API 服务可能按请求或 Token 收费，具体价格、配额、数据保留与隐私规则由所使用的服务商决定，请在启用前自行确认。服务地址必须使用 HTTPS；仅 `localhost`/loopback 本机兼容服务可使用 HTTP，带凭据的请求不会自动跟随重定向。成功译文缓存在 `%LOCALAPPDATA%\BinToAudioWindows\Lyrics\Translation-v2`，缓存不包含 API Key，并绑定服务端点、API 格式/版本、模型、Prompt、歌曲上下文和原歌词；删除对应缓存可强制重新翻译。

## 自动 CI/CD

仓库内置 GitHub Actions：

- **CI**：Pull Request、推送到 `main`/`gui` 或手动运行时，在 Ubuntu 24.04 检查 Bash 语法、ShellCheck 和 Linux 转换器离线 dry-run；在 Windows Server 2025 使用固定的 .NET 8 SDK 还原、构建并检查 GUI（包括嵌入转换脚本），再验证 `win-x64` 自包含发布目录恰好只有一个 EXE；同时分别使用 PowerShell 7 与 Windows PowerShell 5.1 解析脚本、运行离线 smoke test，并执行关键 PSScriptAnalyzer 规则。
- **CD**：推送指向 `main` 历史的 SemVer 标签（例如 `v2.8.0`）后，先复用完整 CI，再在 Windows 构建并实际自检自包含 `win-x64` 单 EXE；随后发布该精确 EXE、可选空白 `.env.example`、Linux tar.gz、内嵌 .NET Runtime 对应的许可证/第三方通知和 `SHA256SUMS.txt`。Windows 用户运行时仍只需下载 EXE，不再需要解压 ZIP、另放 PowerShell 脚本或安装 .NET Runtime。
- GitHub Actions 依赖固定到完整提交 SHA，并由 Dependabot 每周检查更新；CI 只拥有仓库读取权限，只有发布作业拥有 `contents: write`。

发布新版本：

```bash
git switch main
git pull --ff-only
git tag v2.8.0
git push origin v2.8.0
```

Release 直接提供 Windows 单 EXE和空白 `.env.example`，Linux tar.gz 仍只包含 Linux 脚本与 README；同页的 .NET `LICENSE` 与 `THIRD-PARTY-NOTICES` 是内嵌 Runtime 的许可资料，不是运行依赖。Release 绝不包含真实 `.env`、API Key、BIN、音频、缓存、歌词或本地生成的元数据。

## 本地歌词命名

Windows 转换器会先在 BIN 所在目录和 `lyrics` 子目录中查找歌词。以下名称均可识别：

```text
01 - 歌曲名.lrc
歌曲名.lrc
track-01.lrc
01.lrc
```

纯文本歌词可使用相同名称和 `.txt` 后缀。本地文件属于显式人工覆盖，优先级高于网易云、QQ 音乐和 LRCLIB。

## 关于 Q 子通道 CRC 提示

`cdrdao` 有时会显示：

```text
Found 92 Q sub-channels with CRC errors.
```

该提示表示部分 Q 子通道帧的 CRC 未通过。Q 子通道主要保存轨道号、时间、INDEX、pregap 和 ISRC 等控制信息，不等同于音频 PCM 扇区损坏。只要读取最终成功，并且没有同时出现 `read error`、`SCSI error`、`uncorrectable`、`Padding with ... zero sectors` 或 `L-EC errors`，少量 Q CRC 通常不致命。

脚本不能根据这条提示只重读 CRC 错误位置：当前 `cdrdao` 对脚本输出的是汇总数量，没有提供可直接重读的逐帧地址；Q 子通道地址也不能可靠等同于需要替换的音频 PCM 区间。强行按该数字覆盖局部镜像，反而可能把正确音频换成另一遍的不稳定结果。`--paranoia-mode 3` 已负责音频读取过程中的重叠检查与可疑区域重读；归档层面再使用双遍完整哈希比较，判断依据更稳妥。

如需提高可信度：

1. 清洁光盘并使用 `--speed 4` 或 `--speed 2` 重新读取。
2. 使用 `--verify-passes 2` 自动低速读取两遍，并同时比较 BIN 和 TOC 的 SHA-256。
3. 如果哈希不同或能听到爆音、跳音，换另一台光驱读取。
4. 不要仅为了隐藏提示使用 `--fast-toc`，否则可能失去详细的 INDEX/pregap 检测。

## 输出与完整性

镜像目录示例（双遍校验一致时）：

```text
艺术家 - 专辑 (2026) [BIN-TOC]/
├── cdrom-YYYYMMDD-HHMMSS.bin
├── cdrom-YYYYMMDD-HHMMSS.toc
├── cdrdao-pass-1.log
├── cdrdao-pass-2.log
├── disc-info.txt
├── dump-metadata.txt
├── verification-report.txt
├── musicbrainz-metadata.json
└── SHA256SUMS
```

若双遍校验不一致，还会额外保留：

```text
verification-pass-2/
├── cdrom-YYYYMMDD-HHMMSS.bin
└── cdrom-YYYYMMDD-HHMMSS.toc
```

增强转换目录示例：

```text
艺术家 - 专辑 (2026) [FLAC]/
├── 01 - 歌曲名.flac
├── 01 - 歌曲名.lrc
├── Subtitles/
│   └── 01 - 歌曲名.srt
├── cover.jpg
├── folder.jpg
├── tracks.m3u8
├── metadata.json
├── musicbrainz-metadata.json
├── lyrics-metadata.json
└── SHA256SUMS.txt
```

校验镜像：

```bash
cd '/path/to/album [BIN-TOC]'
sha256sum --check SHA256SUMS
```

## 限制与注意事项

- 两个音轨转换器仅支持纯 CD-DA TOC；遇到数据轨或混合模式 TOC 会拒绝转换。
- `dump_cdrom.sh` 可以归档混合模式 CD，但后续应使用理解对应数据轨格式的工具处理。
- WAV 对封面和自定义歌词标签的播放器兼容性有限，因此脚本始终保留同名歌词旁挂文件。
- 只有带时间戳的 `.lrc` 能准确转换为 SRT；纯文本 `.txt` 没有时间信息，因此仍只作为歌词旁挂文件保留。
- 不同发行版、再版和地区版可能共享相似曲目表。出现多个 MusicBrainz 匹配时请确认发行日期、国家和介质序号。
- 逐轨国内匹配仍要求候选属于同名专辑；国内平台只把附赠曲收录在另一张专辑时会保留 MusicBrainz 标签并继续使用后续歌词源，这是有意的防误配策略。
- CD 音频本身通常不包含可搜索的专辑名，因此 MusicBrainz 仍承担首要 Disc ID/TOC 身份识别。若 MusicBrainz 完全没有该光盘，脚本只会采用同目录已有 JSON、TOC CD-TEXT 或结构明确的目录名作为提示；国内候选未通过整专轨数和时长校验时仍降级为基础轨号，不会仅凭名字猜专辑。
- 在线查询会向元数据服务发送 Disc ID、专辑/歌曲名称和时长，不会上传音频内容。
- 只有显式配置并启用翻译回退后，歌词原文才会发送给所选 Google 或 AI API；曲名/艺人/专辑上下文只发送给 AI API 用于消歧。音频文件始终只在本地处理。API 可能产生费用，并受对应服务商的隐私和数据保留政策约束。GUI 的 Key 不进入参数、预览、日志、EXE 或 Release；选择记住时，设置文件中也只保存当前 Windows 用户 DPAPI 密文。
- 网易云音乐接口不是稳定的公开开发者 API，若服务端以后改变响应格式，脚本会安全回退到 MusicBrainz 标题，不会阻止音频转换。
- 请仅归档和转换你有权处理的光盘与歌词。

## 使用的在线服务

- [MusicBrainz](https://musicbrainz.org/)：Disc ID、发行版和曲目信息
- [网易云音乐](https://music.163.com/)：经时长验证后的规范曲名、多艺人、歌曲 ID、原文歌词、中文翻译及可用罗马音
- [QQ 音乐](https://y.qq.com/)：国内展示曲名、艺人、专辑日期、封面、歌曲 MID、原文歌词及中文翻译
- [Cover Art Archive](https://coverartarchive.org/)：精确发行版与发行组封面
- [Apple iTunes Search API](https://performance-partners.apple.com/search-api)：年份/流派交叉验证及高置信度封面回退
- [Deezer](https://developers.deezer.com/api)：高置信度封面回退
- [Wikidata](https://www.wikidata.org/) / [Wikimedia Commons](https://commons.wikimedia.org/)：发行日期、流派及 P18 封面回退
- [LRCLIB](https://lrclib.net/)：同步及纯文本歌词
- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) / [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create)：无平台中文时优先使用的可选 AI 翻译回退，也支持遵循相同请求格式的兼容服务
- [Google Cloud Translation Basic v2](https://cloud.google.com/translate/docs/reference/rest/v2/translate)：AI 不可用或失败后的可选机器翻译回退
- [musicbrainz.eu](https://musicbrainz.eu/)：MusicBrainz 查询镜像

## 安全说明

仓库不包含服务器地址、账号、密码、API Token、光盘镜像、缓存或用户媒体文件。`.env.example` 只有空白占位符；真实 `.env` 已被忽略且不会打入发布包。GUI 不会把 Key 写入命令行、预览、日志、EXE 或 Release；只有用户主动选择记住时，`settings.json` 才保存 Windows 当前用户 DPAPI 密文。运行前请检查输出目录权限，妥善保存生成的 BIN 文件和 API Key。
