# CD-ROM Dump Tools

一套用于完整读取 CD、保存 BIN/TOC 镜像，以及将 CD-DA 音轨转换为 FLAC/WAV 的脚本。

项目同时提供 Linux 服务器端的光盘镜像脚本和 Windows 本地增强转换脚本。Windows 版本能够自动查询专辑与曲目信息、重命名文件、写入封面和标签，并获取同步歌词。

## 文件说明

| 文件 | 平台 | 用途 |
| --- | --- | --- |
| `dump_cdrom.sh` | Linux | 从实体光驱读取完整 CD，生成 BIN/TOC、校验和及读取信息 |
| `bin_to_audio.sh` | Linux | 将纯 CD-DA 的 BIN/TOC 拆分为基础 FLAC/WAV 音轨 |
| `bin_to_audio_windows.ps1` | Windows | 增强转换器：拆轨、元数据、年份/流派比对、封面、歌词和自动命名 |
| `bin_to_audio_windows.cmd` | Windows | 拖放式启动器，默认调用 PowerShell 脚本转换为 FLAC |

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
- 使用 MusicBrainz、Apple iTunes Search 和 Wikidata 比对年份及流派。
- 流派标签优先采用英文，并统一常见大小写与本地化名称（例如 `テクノ` → `Techno`、`アニメ` → `Anime`、`j-pop` → `J-Pop`）；同一专辑的全部曲目写入相同流派。
- 封面按“Cover Art Archive 精确发行版 → Cover Art Archive 发行组 → Apple iTunes Search → Deezer → Wikidata/Wikimedia Commons”顺序自动回退。
- Windows PowerShell 5.1 下使用 .NET 二进制流保存封面，兼容含中文、日文等非 ASCII 字符的输出路径；本地写盘错误不会再被误判为网络故障反复等待。
- Apple 和 Deezer 候选会按专辑名/别名、艺人、轨数及年份交叉评分，低置信度图片不会写入；下载内容还会经 FFmpeg 解码验证并统一转换为 JPEG。
- 生成 `cover.jpg`、`folder.jpg`，并把封面嵌入 FLAC；实际采用的来源、URL、匹配依据和置信度记录在 `musicbrainz-metadata.json`。
- 自动命名为 `01 - 歌曲名.flac`。
- 默认目录名：`艺术家 - 专辑 (年份) [FLAC/WAV]`。
- 本地 `.lrc/.txt` 歌词优先；没有时使用 LRCLIB 精确匹配和高置信度搜索。
- LRCLIB 响应始终从原始字节按 UTF-8 解码，兼容 Windows PowerShell 5.1 的非 ASCII JSON。
- 严格字段搜索无结果或置信度不足时，自动使用“歌手＋曲名”的宽泛搜索回退。
- 根据 `Instrumental`、`Off Vocal`、`Karaoke` 等标题标记识别纯音乐，不再计入歌词缺失。
- 歌词结果区分 `found`、`instrumental`、`not_found`、`low_confidence` 和 `network_error`。
- 同步歌词保存为同名 `.lrc`，纯文本歌词保存为 `.txt`。
- 同步 `.lrc` 会同时转换为 UTF-8 SRT，集中保存到输出目录的 `Subtitles/` 文件夹；文件名与音频一致，可供 VLC 等播放器加载。
- FLAC 写入 `LYRICS`、`SYNCEDLYRICS`、`LYRICS_SOURCE` 标签。
- 纯音乐会标记为 `instrumental`，不会写入伪歌词。
- 输出 `musicbrainz-metadata.json`、`lyrics-metadata.json`、播放列表和 SHA-256 校验和。
- MusicBrainz 请求全局限制为最多每 1.1 秒一次；遇到 429、503 或临时 5xx 时遵循 `Retry-After` 或指数退避，最多重试 5 次后再使用镜像/缓存。
- 在线服务不可用时使用 30 天缓存、多源回退或降级转换，不中断音频处理。
- 歌词缓存使用 `LRCLIB-v2` 命名空间，自动绕过旧版可能存在的乱码或错误空结果缓存。

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

MusicBrainz 要求客户端不超过每秒一次请求。脚本会在所有 MusicBrainz 主站请求之间统一等待 1.1 秒，并缓存结果；HTTP 503 既可能是当前 IP/客户端速率过高，也可能是服务整体繁忙，因此脚本会自动退避重试，不会立即丢弃专辑信息。Apple Search API 也有独立节流和 30 天缓存。

### 拖放使用

将 `.bin` 文件拖到 `bin_to_audio_windows.cmd` 上，脚本会查找同目录同名 `.toc`，默认输出 FLAC。

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
```

可选开关：

```powershell
# 不查询在线元数据
-NoMetadata

# 不下载或嵌入封面
-NoCover

# 不查询、保存或嵌入歌词
-NoLyrics

# MusicBrainz 返回多个发行版本时选择指定序号
-ReleaseIndex 2
```

## 本地歌词命名

Windows 转换器会先在 BIN 所在目录和 `lyrics` 子目录中查找歌词。以下名称均可识别：

```text
01 - 歌曲名.lrc
歌曲名.lrc
track-01.lrc
01.lrc
```

纯文本歌词可使用相同名称和 `.txt` 后缀。本地歌词优先级高于 LRCLIB。

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
- 在线查询会向元数据服务发送 Disc ID、专辑/歌曲名称和时长，不会上传音频内容。
- 请仅归档和转换你有权处理的光盘与歌词。

## 使用的在线服务

- [MusicBrainz](https://musicbrainz.org/)：Disc ID、发行版和曲目信息
- [Cover Art Archive](https://coverartarchive.org/)：精确发行版与发行组封面
- [Apple iTunes Search API](https://performance-partners.apple.com/search-api)：年份/流派交叉验证及高置信度封面回退
- [Deezer](https://developers.deezer.com/api)：高置信度封面回退
- [Wikidata](https://www.wikidata.org/) / [Wikimedia Commons](https://commons.wikimedia.org/)：发行日期、流派及 P18 封面回退
- [LRCLIB](https://lrclib.net/)：同步及纯文本歌词
- [musicbrainz.eu](https://musicbrainz.eu/)：MusicBrainz 查询镜像

## 安全说明

仓库不包含服务器地址、账号、密码、API Token、光盘镜像、缓存或用户媒体文件。运行前请检查输出目录权限，并妥善保存生成的 BIN 文件。
