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
- 采用选定发行版的曲名、艺人、专辑、日期和 MusicBrainz ID 命名并写标签；从 Cover Art Archive 尽力下载精确发行版封面，FLAC 会嵌入封面，WAV 保留 sidecar 图片。
- 输出 `conversion-metadata.json`、`tracks.m3u8` 和覆盖全部成品的 `SHA256SUMS.txt`。
- 输出保存在应用 Documents 的 `CD-ROM Dump Tools/`，可在“文件”App 中取出或通过系统分享表共享目录。
- 支持进度、日志、取消、防自动锁屏和进入后台提示；失败或取消不会修改原始 BIN/TOC。

## 与桌面版的差异

这是首个原生 iOS 转换器，不是 Windows/macOS 增强转换器的完整等价版。当前 iOS 包尚未移植网易云、QQ 音乐、Apple/Deezer/Wikidata 多源比对、在线歌词、SRT、中文/AI 翻译和桌面 `.env`/Keychain 模型配置。需要这些功能时，请先使用桌面版完成增强刮削，再把成品传到 iPhone。

由于 iOS 普通后台任务可能被系统暂停，转换一张完整 CD 时应保持应用在前台并连接电源。系统 FLAC 编码器若在特定设备上不可用，应用会明确报错并建议改选 WAV，不会把其他格式伪装成 `.flac`。

## 构建

构建脚本要求 Apple Silicon macOS、Xcode 26.6、iOS 26.x device/simulator SDK：

```bash
VERSION=2.13.0 \
BUILD_NUMBER=1 \
OUTPUT_DIR="$PWD/dist" \
bash ios/build_ios_ipa.sh
```

脚本会：

1. 在 macOS 上运行 TOC、pregap Disc ID、WAV、FLAC 和解码 PCM 哈希的离线核心自检。
2. 编译通用 iOS 26 Simulator 目标，但不启动模拟器，因此这里只称为“模拟器编译验证”。
3. 编译 `arm64-apple-ios26.0` device 二进制并生成 `Payload/CdromDumpToolsIOS.app`。
4. 核对版本、`MinimumOSVersion=26.0`、Mach-O 平台/SDK/arm64 架构和 IPA ZIP 结构。
5. 拒绝包含 `_CodeSignature`、provisioning profile、真实 `.env`、证书或私钥的包。

输出：

```text
cdrom-dump-tools-2.13.0-ios26-arm64-unsigned.ipa
```

## 未签名分发限制

公开 Release 中的 IPA **故意不签名，也不包含 provisioning profile**，不能直接安装到普通 iPhone。安装前必须使用你自己的 Apple Developer 身份和匹配的 provisioning profile 重签名；本仓库和 GitHub Actions 不保存任何 Apple 证书或私钥。

`unsigned` 会始终保留在文件名、Release 警告和应用包内的 `UNSIGNED-NOTICE.txt` 中。成功编译、打包和 ZIP 校验不等于已在实体 iPhone 上完成安装或运行测试。
