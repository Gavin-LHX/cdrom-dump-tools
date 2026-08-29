# Linux GNOME 版

Linux 桌面应用使用 GTK4 与 libadwaita，面向 Ubuntu 24.04 及更新版本和 Debian 12/13。它调用与 Windows、macOS 相同的增强转换引擎，因此保留 MusicBrainz 光盘识别、网易云/QQ 标签、封面、歌词、AI 翻译、字幕和逐轨无损校验。Ubuntu 22.04 自带的 libadwaita 1.1 缺少本界面需要的控件，不在支持范围内。

## 安装

按机器架构下载 `ubuntu-debian-amd64.deb` 或 `ubuntu-debian-arm64.deb`，然后使用 apt 安装；apt 会自动补齐 FFmpeg、GTK4、libadwaita、Noto CJK 中文字体和 GNOME Keyring 工具：

```bash
sudo apt install ./cdrom-dump-tools-*-ubuntu-debian-$(dpkg --print-architecture).deb
```

安装后从 GNOME 应用菜单打开“CD 光盘镜像转换”，或执行：

```bash
cdrom-dump-tools
```

API Key 可仅保留在当前进程中，或由用户主动选择保存到 GNOME Keyring；普通设置文件和命令预览不会包含 Key。`.env.example` 安装在 `/usr/share/doc/cdrom-dump-tools/env.example`。

## 自检

```bash
cdrom-dump-tools --self-test
```

`.deb` 内置官方固定版本 PowerShell runtime，但使用发行版提供的 FFmpeg。程序拒绝以 root 身份转换，避免高权限进程误用用户文件或密钥。

## 卸载与用户数据

```bash
sudo apt purge cdrom-dump-tools
```

Debian 规范要求卸载系统包时保留用户自己的设置、缓存与 Keyring 项目，因此 `apt purge` 不会扫描或删除 `/home`。如需彻底清理，请由对应用户自行删除 `~/.config/cdrom-dump-tools`、`~/.cache/cdrom-dump-tools`，并在“密码和密钥”中删除 CD-ROM Dump Tools 项目。
