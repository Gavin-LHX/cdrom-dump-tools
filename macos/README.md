# macOS arm64 / Intel x64 构建与发布

此目录提供 macOS 14 及更高版本的原生 SwiftUI 应用构建基础设施，同时支持 Apple Silicon（`arm64`）和 Intel（`x86_64`，资产名使用 `x64`）。Release 生成两份独立 DMG，而不是把两套运行时合并成一个 Universal 包：

- Apple Silicon：`cdrom-dump-tools-<版本>-macos-arm64-unsigned.dmg`
- Intel Mac：`cdrom-dump-tools-<版本>-macos-x64-unsigned.dmg`

请按 Mac 的处理器选择对应资产。Apple Silicon 版和 Intel 版会分别内置同架构的 PowerShell 7.6.5、从 FFmpeg 官方 `n8.1.2` 源码编译的 LGPL FFmpeg，以及仓库根目录的增强转换脚本；正常运行不依赖 Rosetta、Homebrew、外部 PowerShell、FFmpeg 或 .NET。macOS 26 及以上使用系统原生 Liquid Glass；macOS 14/15 自动使用 Material 背景回退，不牺牲原有系统兼容性。

## 重要的分发限制

当前两种架构的 DMG **均仅使用 ad-hoc 签名，没有 Apple Developer ID 签名，也没有经过 Apple 公证**。资产名固定包含 `unsigned`，应用界面和 DMG 内说明也会显示这一状态。Gatekeeper 可能阻止从互联网下载的副本启动；这些产物适合 CI 验证和知情测试，不应描述为已签名、公证或 Gatekeeper-ready。不要通过删除 `com.apple.quarantine` 属性来掩盖这一限制。

正式公开分发前仍需 Apple Developer Program 凭据、Developer ID Application 签名、Hardened Runtime、对嵌套 PowerShell/.NET 运行时所需 entitlement 的实机验证、`notarytool` 公证和 ticket stapling。本脚本故意不伪造这些步骤。

## 固定上游输入

| 组件 | 上游资产 | SHA-256 |
| --- | --- | --- |
| PowerShell（Apple Silicon） | `powershell-7.6.5-osx-arm64.tar.gz` | `8196d4b4e7c21b7f6df9d45687bb4e42dc8335f330b580d9eb15f3ef5042a8c3` |
| PowerShell（Intel） | `powershell-7.6.5-osx-x64.tar.gz` | `3db1d177ab39511c1b6b73b05a1630a5db4e8dce22857ca76f14c5d98f2733fd` |
| FFmpeg | `FFmpeg/FFmpeg` tag `n8.1.2` 源码包 | `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7` |

脚本按目标架构选取对应的 PowerShell 资产，并在解包前强制核对表中的哈希；FFmpeg 源码包同样必须通过哈希验证。FFmpeg 使用静态内部库构建，显式禁用 GPL、nonfree、version3 和第三方库自动探测，只额外启用 macOS 系统 zlib 以保留 PNG 封面解码；构建后会检查 `-buildconf`，并拒绝链接 Homebrew 或其他非系统动态库的结果。随包保留 FFmpeg 和 PowerShell 的许可/第三方通知文件。

## 本地构建

构建机必须安装 Xcode 26 或更高版本（含 macOS 26 SDK 和 SwiftUI 编译插件），并可访问 GitHub；仅安装 Command Line Tools 的机器可能缺少 `SwiftUIMacros`，不足以编译此应用。脚本会在 Xcode 或 SDK 低于 26 时立即退出，避免生成一个实际上没有原生 Liquid Glass 路径的旧外观包。最低运行系统仍为 macOS 14。

构建脚本会在构建期间实际启动目标架构的 PowerShell、FFmpeg 和主程序，因此构建宿主必须与 `TARGET_ARCH` 一致：Apple Silicon 主机原生构建 `arm64`，Intel 主机原生构建 `x86_64`。不要依赖 Rosetta 或交叉编译来替代对应架构的验证。`TARGET_ARCH` 省略时默认使用当前宿主架构；版本默认从 Windows GUI 项目的 `<Version>` 读取。

在 Apple Silicon Mac 构建：

```bash
TARGET_ARCH=arm64 \
BUILD_NUMBER=1 \
OUTPUT_DIR="$PWD/dist/macos" \
bash macos/build_macos_app.sh
```

输出文件为 `dist/macos/cdrom-dump-tools-<版本>-macos-arm64-unsigned.dmg`。

在 Intel Mac 构建：

```bash
TARGET_ARCH=x86_64 \
BUILD_NUMBER=1 \
OUTPUT_DIR="$PWD/dist/macos" \
bash macos/build_macos_app.sh
```

输出文件为 `dist/macos/cdrom-dump-tools-<版本>-macos-x64-unsigned.dmg`。

两个 DMG 是平行产物：Intel Mac 运行 x64 版时不需要 Rosetta；Apple Silicon 用户应使用 arm64 版。虽然 Apple Silicon 可在安装 Rosetta 后运行部分 x86_64 程序，但这不是 Intel 包的目标运行方式，也不能代替真实 Intel Mac 的原生测试。

可选环境变量：

- `TARGET_ARCH`：`arm64` 或 `x86_64`；默认当前宿主架构，并且必须与宿主原生架构一致。
- `VERSION`：必须与 Windows GUI 项目版本和根转换脚本组件版本一致。
- `BUILD_NUMBER`：写入 `CFBundleVersion` 的纯数字构建号；默认 `1`。
- `BUNDLE_IDENTIFIER`：反向域名格式；默认 `com.gavinlhx.cdrom-dump-tools`。
- `DOWNLOAD_CACHE_DIR`：保存已校验上游压缩包的本地缓存目录。
- `OUTPUT_DIR`：DMG 输出目录。

## 构建内验证

`build_macos_app.sh` 会对所选架构完成以下检查：

- 构建环境必须是 Xcode 26/macOS 26 SDK 或更高版本；编译目标为当前选择的 `arm64` 或 `x86_64`，最低 macOS 版本固定为 14。
- 主程序与 FFmpeg 必须只包含目标架构；官方 PowerShell 包内的每个 Mach-O 必须包含可运行的目标架构 slice。
- `Info.plist` 语法、架构优先级、bundle ID、最低系统版本、发布版本、构建号和“未公证”标记准确。
- FFmpeg 配置明确禁用 GPL/nonfree/version3，且仅链接 macOS 系统动态库。
- 应用及嵌套 Mach-O 可通过严格 ad-hoc `codesign` 验证。
- 原生程序的 `--self-test` 能解析嵌入 PowerShell 脚本，并实际启动捆绑的 PowerShell 与 FFmpeg。
- 从最终 DMG 挂载路径使用内置 PowerShell/FFmpeg 完成一个无网络的两秒 BIN/TOC → FLAC 转换及逐轨 PCM 校验。
- 最终 DMG 可通过 `hdiutil verify`，挂载后的应用再次通过以上验证和 self-test。

GitHub Actions 使用两台与目标架构一致的 macOS 26/Xcode 26 runner 分别执行构建与以上验证：Apple Silicon runner 产出 `macos-arm64`，Intel runner 产出 `macos-x64`。这会覆盖两种 CPU 上的原生 PowerShell/FFmpeg 启动、转换和签名链路，不以 Apple Silicon 上的 Rosetta 测试冒充 Intel 原生验证。macOS 14/15 会由代码中的系统版本可用性检查选择 Material 回退；发布前如需把最低系统兼容性也作为实机证据，仍应在相应版本的 Intel 与 Apple Silicon 系统上运行最终 DMG。

手工检查已挂载 DMG 中的应用：

```bash
APP="/Volumes/CD-ROM Dump Tools/CdromDumpTools.app"
plutil -p "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/CdromDumpTools"
lipo -archs "$APP/Contents/Resources/runtime/powershell/pwsh"
lipo -archs "$APP/Contents/Resources/runtime/ffmpeg"
codesign --verify --deep --strict --verbose=4 "$APP"
"$APP/Contents/MacOS/CdromDumpTools" --self-test
```

`codesign` 成功只说明 ad-hoc 签名内部一致，不代表身份签名或 Apple 公证成功。
