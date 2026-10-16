# 映想 · Imagyn

一个克制的 AI 图像创作客户端：**画廊**和 **Agent** 两个入口，自带 API Key，直连任意兼容服务，作品留在你自己的设备上。跨 Android、Linux、Windows、macOS，界面支持联合国六种工作语言。

> 状态：**开发中。** 支持范围请看[能力边界](#能力边界)，不要把它当成"接上任何兼容地址就能出图"。（第一次做这类应用，请见谅）

## 两个入口

| 入口 | 做什么 |
| --- | --- |
| **画廊** | 输入提示词，附零张或多张参考图，直接出图。参考图按编号排列，可以在提示词里写"图 1 的人物、图 2 的衣服"。 |
| **Agent** | 对话式生成与连续修改。讨论和生成分开显示状态，普通聊天不会悄悄触发收费生图；每次修改存为独立版本，旧图可回看，生成的图片同样出现在画廊。 |

设置单独成页，分为「生图 / Agent / 通用」三个页签。对话内可以切换模型，按模型自定义系统提示词、上下文消息数量和输出参数；聊天历史与草稿保留。支持减少动态效果。

## 特性

- **本地优先**：历史用 SQLite 存在应用私有目录，作品是本地文件，不依赖临时地址；API 密钥进系统安全存储，不写进数据库。
- **自带服务**：自定义基础地址、图片模型与对话模型、协议（OpenAI Chat Completions / OpenAI Responses / Anthropic Messages）、可选 HTTP 代理；对话模型与图片模型可以分属不同服务。
- **任务状态如实**：区分提交失败、结果未知、生成中、下载失败。提交后超时不自动重发收费请求，而是保留"状态未知"并交给你判断。
- **六语言**：中文、English、Français、Español、Русский、العربية，含阿拉伯语从右到左布局。
- **无 root 安卓**：生成图片经系统媒体接口另存到公共 `Pictures/Imagyn/`，相册可见；参考图走系统文件选择器多选，不依赖 Google Play 服务。

## 能力边界

"OpenAI / Claude 兼容"只声明协议格式，**不保证**生图、参考图数量、透明背景、分辨率或任务恢复。第一版明确实现的和没实现的：

| 接口 | 状态 |
| --- | --- |
| OpenAI Images（`images/generations`、`images/edits`） | 已实现，含多参考图编辑、URL 与 Base64 输出 |
| OpenAI Chat Completions + `generate_image` 工具 | 已实现（Agent 模式，`/chat/completions`） |
| OpenAI Responses + `generate_image` 工具 | 已实现（Agent 模式，`/responses`） |
| Anthropic Messages + `generate_image` 工具 | 已实现（Agent 模式） |
| OpenAI Images SSE 流式结果 | 已实现，可在图片接口兼容选项中开启 |
| OpenAI Responses 内置 `image_generation` 工具 | 未实现；Agent 使用应用的 `generate_image` 调用独立 Images 接口 |
| 蒙版编辑、批量任务、云同步、本地推理 | 未实现，属后续扩展 |

模型列表本身不能证明生图能力，连接检查也不等于生图测试。付费的生成测试由你在画廊主动触发。细节见 [docs/capabilities.md](docs/capabilities.md)。

## 构建

需要 Flutter（Dart SDK ≥ 3.12）。

平台目录不入库，由脚本生成后叠加本仓库自有文件：

```bash
python3 scripts/scaffold_platforms.py     # 生成 android/ linux/ windows/ macos/
flutter pub get
flutter run -d <device>
flutter build apk --release
```

CI 分三条流水线：`check`（分析 + 单元测试）、`build`（Android APK 测试包）、`release`（`v*` 标签触发，四平台打包）。

发布产物：

| 平台 | 产物 | 打包方式 |
| --- | --- | --- |
| Android | APK | 已签名（release keystore） |
| Linux | `.deb` / `.rpm` / `.pkg.tar.zst` | `dpkg-deb` / `rpmbuild` / `bsdtar` |
| Windows | `.exe` / `.msi`（仅 x64） | Inno Setup / WiX |
| macOS | `.dmg` / `.pkg` | `hdiutil` / `pkgbuild` |

桌面产物**没有签名**：Windows SmartScreen 会提示「未知发布者」，macOS 需要右键打开。消除这一点需要 Authenticode 证书和 Apple Developer ID（但是作者没有…）。Windows **没有 32 位版本** —— Flutter 不提供 32 位 Windows 目标。所以暂时对不住 Windows 7 和其它 win32 用户。

## 结构

```
lib/core/    数据层 store、数据模型 models、协议适配 api、应用状态 studio
lib/ui/      shell（画廊 + Agent）、settings（设置）
lib/l10n/    六语言文案与查表
platform/    各平台自有原生文件，叠加到 flutter create 的产物上
scripts/     平台脚手架、文案生成
docs/        接口与功能使用说明
test/        协议解析、配置校验、文案一致性
```

## 文档

- [docs/image-workflow.md](docs/image-workflow.md) — 图片接口、画廊与提交行为
- [docs/agent-settings.md](docs/agent-settings.md) — 设置分栏、对话内切换模型与自定义提示词/上下文参数
- [docs/capabilities.md](docs/capabilities.md) — 接口能力矩阵与降级规则

## 许可证

**GPL-3.0-or-later**，全文见 [LICENSE](LICENSE)。选用它有一个连带义务：**分发二进制时必须提供对应源码**。本仓库公开即可满足，发布页也会附带 `-source.tar.gz`。若将来想闭源分发，必须先换许可证。

---

## English

# Imagyn

A minimalist AI image creation app with two entry points: **Gallery** and **Agent**. Bring your own API key and connect directly to a compatible service. Your artwork stays on your device. Available for Android, Linux, Windows and macOS, with an interface in the six official UN languages.

> Status: **work in progress.** See [Supported features](#supported-features) for the scope of support; connecting a compatible endpoint does not automatically guarantee image generation. This is my first app of this kind—thanks for your patience.

### Two entry points

| Entry point | What it does |
| --- | --- |
| **Gallery** | Generate images from a prompt, with zero or more reference images. References are numbered, so you can ask for “the person from image 1 wearing the clothes from image 2.” |
| **Agent** | Generate and refine images through conversation. Discussion and generation have separate status indicators; ordinary chat does not silently trigger paid image generation. Each edit is saved as a separate version, and generated images also appear in the gallery. |

Settings has its own page with three tabs: **Images / Agent / General**. Switch models during a conversation and customize each model’s system prompt, context message count and output parameters while keeping your history and draft. Reduced motion is also supported.

### Features

- **Local first:** History is stored in SQLite in the app’s private directory. Artwork is saved as local files rather than depending on temporary URLs. API keys use the system’s secure storage, not the database.
- **Bring your own service:** Configure base URLs, image and chat models, the protocol (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages), and an optional HTTP proxy. Chat and image models can use different services.
- **Clear task states:** Submission failures, unknown results, generation in progress and download failures are shown separately. A timeout after submission never automatically resends a paid generation request; the result stays “unknown” for you to check.
- **Six languages:** 中文, English, Français, Español, Русский and العربية, including right-to-left Arabic layout.
- **Android without root:** Save generated images to the public `Pictures/Imagyn/` folder through the system media API, where gallery apps can see them. Select multiple reference images with the system file picker. Google Play Services is not required.

### Supported features

“OpenAI / Claude compatible” describes a request format. It **does not guarantee** image generation, reference image limits, transparent backgrounds, resolutions or task recovery. The current implementation includes:

| API or feature | Status |
| --- | --- |
| OpenAI Images (`images/generations`, `images/edits`) | Implemented, including multiple reference images and URL / Base64 output |
| OpenAI Chat Completions + `generate_image` | Implemented in Agent mode (`/chat/completions`) |
| OpenAI Responses + `generate_image` | Implemented in Agent mode (`/responses`) |
| Anthropic Messages + `generate_image` | Implemented in Agent mode |
| OpenAI Images SSE results | Implemented; enable it in the image API compatibility options |
| Responses built-in `image_generation` tool | Not implemented; Agent uses the app’s `generate_image` function to call the separate Images API |
| Mask editing, batch jobs, cloud sync, local inference | Not implemented; possible future extensions |

A model list does not prove image generation capability, and a connection check is not an image generation test. Paid generation tests are only started when you explicitly submit a request in the gallery. See [docs/capabilities.md](docs/capabilities.md) for details.

### Build

Requires Flutter with Dart SDK ≥ 3.12.

Platform directories are generated rather than tracked in Git. The script then overlays the native files owned by this repository:

```bash
python3 scripts/scaffold_platforms.py     # Generate android/ linux/ windows/ macos/
flutter pub get
flutter run -d <device>
flutter build apk --release
```

CI has three workflows: `check` (analysis and tests), `build` (Android test APK), and `release` (four-platform packaging triggered by `v*` tags).

Release packages:

| Platform | Packages | Packaging tools |
| --- | --- | --- |
| Android | APK | Signed with the release keystore |
| Linux | `.deb` / `.rpm` / `.pkg.tar.zst` | `dpkg-deb` / `rpmbuild` / `bsdtar` |
| Windows | `.exe` / `.msi` (x64 only) | Inno Setup / WiX |
| macOS | `.dmg` / `.pkg` | `hdiutil` / `pkgbuild` |

Desktop packages **are unsigned**: Windows SmartScreen displays an “unknown publisher” warning, and macOS requires opening the app with a right-click. Avoiding these warnings requires an Authenticode certificate and an Apple Developer ID, which I don’t have yet. There is **no 32-bit Windows build** because Flutter does not provide a 32-bit Windows target. Sorry to Windows 7 and other win32 users for now.

### Project layout

```text
lib/core/    Storage, data models, API adapters and application state
lib/ui/      Gallery / Agent shell and settings
lib/l10n/    Six-language text and lookup tables
platform/    App-owned native files overlaid onto flutter create output
scripts/     Platform scaffolding and translation generation
docs/        API and feature usage guides
test/        Protocol parsing, configuration validation and translation checks
```

### Documentation

The following guides are currently in Chinese:

- [Image workflow](docs/image-workflow.md) — Image API behavior, gallery and submission behavior
- [Agent settings](docs/agent-settings.md) — Settings tabs, model switching, custom prompts and context parameters
- [Capabilities](docs/capabilities.md) — API support matrix and failure handling

### License

**GPL-3.0-or-later**. See [LICENSE](LICENSE) for the full text. Distributing binaries requires making the corresponding source available. This repository is public, and release assets also include a `-source.tar.gz` archive. Any future proprietary distribution would require a license change first.
