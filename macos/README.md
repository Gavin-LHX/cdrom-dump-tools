# macOS arm64 构建与发布

此目录提供 macOS 14 及更高版本的 Apple Silicon（arm64）原生 SwiftUI 应用构建基础设施。构建脚本会把仓库根目录的增强转换脚本、官方 PowerShell 7.6.5 arm64 发行包，以及从 FFmpeg 官方 `n8.1.2` 源码编译的 LGPL FFmpeg 放进应用包，最终生成一个 DMG。

## 重要的分发限制

当前 DMG **仅使用 ad-hoc 签名，没有 Apple Developer ID 签名，也没有经过 Apple 公证**。资产名固定包含 `unsigned`，应用界面和 DMG 内说明也会显示这一状态。Gatekeeper 可能阻止从互联网下载的副本启动；该产物适合 CI 验证和知情测试，不应描述为已签名、公证或 Gatekeeper-ready。不要通过删除 `com.apple.quarantine` 属性来掩盖这一限制。

正式公开分发前仍需 Apple Developer Program 凭据、Developer ID Application 签名、Hardened Runtime、对嵌套 PowerShell/.NET 运行时所需 entitlement 的实机验证、`notarytool` 公证和 ticket stapling。本脚本故意不伪造这些步骤。

## 固定上游输入

| 组件 | 上游资产 | SHA-256 |
| --- | --- | --- |
| PowerShell | `powershell-7.6.5-osx-arm64.tar.gz` | `8196d4b4e7c21b7f6df9d45687bb4e42dc8335f330b580d9eb15f3ef5042a8c3` |
| FFmpeg | `FFmpeg/FFmpeg` tag `n8.1.2` 源码包 | `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7` |

脚本在解包前强制核对这两个哈希。FFmpeg 使用静态内部库构建，显式禁用 GPL、nonfree、version3 和第三方库自动探测，只额外启用 macOS 系统 zlib 以保留 PNG 封面解码；构建后会检查 `-buildconf`，并拒绝链接 Homebrew 或其他非系统动态库的结果。随包保留 FFmpeg 和 PowerShell 的许可/第三方通知文件。

## 本地构建

构建机必须是 arm64 Mac，安装包含 SwiftUI 编译插件的完整 Xcode，并可访问 GitHub；仅安装 Command Line Tools 的机器可能缺少 `SwiftUIMacros`，不足以编译此应用。默认从 Windows GUI 项目的 `<Version>` 读取发布版本：

```bash
BUILD_NUMBER=1 \
OUTPUT_DIR="$PWD/dist/macos" \
bash macos/build_macos_app.sh
```

输出文件为：

```text
dist/macos/cdrom-dump-tools-<version>-macos-arm64-unsigned.dmg
```

可选环境变量：

- `VERSION`：必须与 Windows GUI 项目版本和根转换脚本组件版本一致。
- `BUILD_NUMBER`：写入 `CFBundleVersion` 的纯数字构建号；默认 `1`。
- `BUNDLE_IDENTIFIER`：反向域名格式；默认 `com.gavinlhx.cdrom-dump-tools`。
- `DOWNLOAD_CACHE_DIR`：保存已校验上游压缩包的本地缓存目录。
- `OUTPUT_DIR`：DMG 输出目录。

## 构建内验证

`build_macos_app.sh` 在成功前会完成以下检查：

- 主程序与 FFmpeg 必须是 `arm64`；官方 PowerShell 包内的 Mach-O 必须包含可运行的 `arm64` slice（个别官方库可能同时带有 `x86_64` slice）。
- `Info.plist` 语法、bundle ID、最低系统版本、发布版本、构建号和“未公证”标记准确。
- FFmpeg 配置明确禁用 GPL/nonfree/version3，且仅链接 macOS 系统动态库。
- 应用及嵌套 Mach-O 可通过严格 ad-hoc `codesign` 验证。
- 原生程序的 `--self-test` 能解析嵌入 PowerShell 脚本，并实际启动捆绑的 PowerShell 与 FFmpeg。
- 从最终 DMG 挂载路径使用内置 PowerShell/FFmpeg 完成一个无网络的两秒 BIN/TOC → FLAC 转换及逐轨 PCM 校验。
- 最终 DMG 可通过 `hdiutil verify`，挂载后的应用再次通过以上验证和 self-test。

手工检查已挂载 DMG 中的应用：

```bash
APP="/Volumes/CD-ROM Dump Tools/CdromDumpTools.app"
plutil -p "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/CdromDumpTools"
codesign --verify --deep --strict --verbose=4 "$APP"
"$APP/Contents/MacOS/CdromDumpTools" --self-test
```

`codesign` 成功只说明 ad-hoc 签名内部一致，不代表身份签名或 Apple 公证成功。
