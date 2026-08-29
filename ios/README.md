# iOS 26 原生版

`ios/` 是专为 iPhone 重写的 SwiftUI 应用，不是把 macOS 的 PowerShell/FFmpeg 运行时塞进 IPA。iOS 不允许普通应用启动这类命令行子进程，也不能直接访问 USB/网络光驱，因此本应用只处理已经由电脑或服务器读取好的 `.bin` + `.toc` 文件。

## 当前功能

- 最低系统为 iOS 26.0，使用 iOS 26 原生 Liquid Glass 界面。
- 从“文件”App 分别导入 CD-DA BIN 与 cdrdao TOC，并在处理期间保持 security-scoped 访问。
- 原生解析 `TRACK AUDIO`、`FILE`/`AUDIOFILE`、`ISRC`、`START` pregap、MSF 与样本帧位置。
- 流式读取 CD-DA `s16be / 44.1 kHz / 16-bit / 2ch`，不会一次把整张 BIN 放进内存。
- 输出 FLAC 或 WAV；FLAC 使用系统 AudioToolbox 编码器，WAV 使用确定性的 RIFF/PCM 写入器。
- 默认逐轨无损校验：把成品重新解码为规范化 CD-DA PCM，再与 BIN 对应字节段比较 SHA-256；任一轨不一致就清理临时目录，不发布半成品。
- 原生计算 MusicBrainz Disc ID。只有一个发行版时自动使用；多个发行版时必须在界面中明确选择，不会偷选第一个。
- MusicBrainz 负责锁定实体光盘发行版；随后网易云与 QQ 音乐都会用专辑名、艺术家、轨数和 CD 实测逐轨时长做整专校验。只有高置信度结果才按可切换的“网易云 → QQ”或“QQ → 网易云”优先级覆盖展示标签；整专失败时还会对单轨执行标题、艺术家、专辑、版本标记和 3 秒时长门槛验证。
- 国内平台验证结果会写入专辑/歌曲 ID，并优先使用其规范曲名、艺人、日期、英文规范化流派和封面；MusicBrainz release/recording ID 始终保留，不会被平台 ID 冒充。封面按首选国内源、次选国内源、Cover Art Archive 回退。
- 在线歌词固定按“网易云 → QQ 音乐 → LRCLIB”查询。网易云和 QQ 同时读取原文、平台中文翻译及可用罗马音；早期来源只有外文时会继续寻找后续中文结果，并过滤纯音乐、`暂无歌词` 等占位响应及把日文汉字误判为中文的情况。
- 网易云、QQ 与 LRCLIB 的在线结果缓存 30 天；缓存过期后会先尝试刷新，网络故障或服务端 503 时才读取过期副本。翻译结果按服务、模型、Endpoint、Prompt、歌曲上下文和原歌词身份长期缓存，不会把 API Key 写进缓存。
- 三个歌词源均无中文时，可选 OpenAI-compatible Chat Completions、Anthropic-compatible Messages、Google Cloud Translation、Microsoft Translator、Google GTX 无 Key、Bing 无 Key 回退。默认顺序为 AI → Google → Microsoft → GTX → Bing，也可在界面切换；内置“信、达、雅”Prompt 使用严格逐行 JSON 对齐，时间戳和双语 LRC/SRT 均在本机重建。
- OpenAI、Anthropic、Google 和 Microsoft 的 API Key 只保存到 `AfterFirstUnlockThisDeviceOnly` 且不可同步的 iOS Keychain；Base URL、模型、翻译模式和自定义 Prompt 保存到 UserDefaults。日志、输出目录和 IPA 都不会包含 Key。只有歌词文本会发送给翻译服务，只有 AI 额外接收曲名、艺人和专辑作为消歧上下文，音频不会上传。
- FLAC 写入封面、年份、英文流派、MusicBrainz/网易云/QQ ID、原文/同步/翻译/罗马音歌词及翻译来源；WAV 同时保留播放器兼容的 INFO 字段和完整旁挂文件。
- 输出同名 `.lrc`/`.txt`、`Subtitles/*.srt`、`metadata.json`、`musicbrainz-metadata.json`、`lyrics-metadata.json`、`conversion-metadata.json`、`audio-verification.json/.txt`、`tracks.m3u8` 和覆盖全部成品的 `SHA256SUMS.txt`。
- 输出保存在应用 Documents 的 `CD-ROM Dump Tools/`，可在“文件”App 中取出或通过系统分享表共享目录。
- 支持进度、日志、取消、防自动锁屏和进入后台提示；失败或取消不会修改原始 BIN/TOC。

## 与桌面版的差异

iOS 已原生移植桌面版的 MusicBrainz → 网易云/QQ 标签链、网易云 → QQ → LRCLIB 歌词链及完整中文/AI 翻译回退，但没有运行或打包 PowerShell/FFmpeg。受沙盒和移动端运行模型限制，当前仍不直接读取实体 USB/网络光驱，也不读取 BIN 同目录的本地歌词覆盖；Apple/Deezer/Wikidata 封面与证据补全仍由桌面版提供。iOS 的密钥配置使用系统 Keychain，而不是读取 `.env`。

由于 iOS 普通后台任务可能被系统暂停，转换一张完整 CD 时应保持应用在前台并连接电源。系统 FLAC 编码器若在特定设备上不可用，应用会明确报错并建议改选 WAV，不会把其他格式伪装成 `.flac`。

## 构建

构建脚本要求 Apple Silicon macOS、Xcode 26.6、iOS 26.x device/simulator SDK：

```bash
VERSION=2.14.0 \
BUILD_NUMBER=1 \
OUTPUT_DIR="$PWD/dist" \
bash ios/build_ios_ipa.sh
```

脚本会：

1. 在 macOS 上运行 TOC、pregap Disc ID、网易云/QQ fixture、歌词合并/SRT、翻译回退、WAV、FLAC 和解码 PCM 哈希的离线核心自检。
2. 编译通用 iOS 26 Simulator 目标，但不启动模拟器，因此这里只称为“模拟器编译验证”。
3. 编译 `arm64-apple-ios26.0` device 二进制并生成 `Payload/CdromDumpToolsIOS.app`。
4. 核对版本、`MinimumOSVersion=26.0`、Mach-O 平台/SDK/arm64 架构和 IPA ZIP 结构。
5. 拒绝包含 `_CodeSignature`、provisioning profile、真实 `.env`、证书或私钥的包。

输出：

```text
cdrom-dump-tools-2.14.0-ios26-arm64-unsigned.ipa
```

## 未签名分发限制

公开 Release 中的 IPA **故意不签名，也不包含 provisioning profile**，不能直接安装到普通 iPhone。安装前必须使用你自己的 Apple Developer 身份和匹配的 provisioning profile 重签名；本仓库和 GitHub Actions 不保存任何 Apple 证书或私钥。

`unsigned` 会始终保留在文件名、Release 警告和应用包内的 `UNSIGNED-NOTICE.txt` 中。成功编译、打包和 ZIP 校验不等于已在实体 iPhone 上完成安装或运行测试。
