# 映想 · Imagyn

一个克制的 AI 图像创作客户端：**画廊**和 **Agent** 两个入口，自带 API Key，直连任意兼容服务，作品留在你自己的设备上。跨 Android、Linux、Windows、macOS，界面支持联合国六种工作语言。

> 状态：**开发中。** 代码已落地，尚未完成四平台实机验收与真实服务联调。支持范围请看[能力边界](#能力边界)，不要把它当成"接上任何兼容地址就能出图"。

## 两个入口

| 入口 | 做什么 |
| --- | --- |
| **画廊** | 输入提示词，附零张或多张参考图，直接出图。参考图按编号排列，可以在提示词里写"图 1 的人物、图 2 的衣服"。 |
| **Agent** | 对话式生成与连续修改。讨论和生成分开显示状态，普通聊天不会悄悄触发收费生图；每次修改存为独立版本，旧图可回看，生成的图片同样出现在画廊。 |

设置单独成页，分为「生图 / Agent / 通用」三个页签。对话内可以切换模型，按模型自定义系统提示词、上下文消息数量和输出参数；聊天历史与草稿保留。支持减少动态效果。

## 特性

- **本地优先**：历史用 SQLite 存在应用私有目录，作品是本地文件，不依赖临时地址；API 密钥进系统安全存储，不写进数据库。
- **自带服务**：自定义基础地址、图片模型与对话模型、协议（OpenAI / Anthropic Messages）、可选 HTTP 代理；对话模型与图片模型可以分属不同服务。
- **任务状态如实**：区分提交失败、结果未知、生成中、下载失败。提交后超时不自动重发收费请求，而是保留"状态未知"并交给你判断。
- **六语言**：中文、English、Français、Español、Русский、العربية，含阿拉伯语从右到左布局。
- **无 root 安卓**：生成图片经系统媒体接口另存到公共 `Pictures/Imagyn/`，相册可见；参考图走系统文件选择器多选，不依赖 Google Play 服务。

## 能力边界

"OpenAI / Claude 兼容"只声明协议格式，**不保证**生图、参考图数量、透明背景、分辨率或任务恢复。第一版明确实现的和没实现的：

| 接口 | 状态 |
| --- | --- |
| OpenAI Images（`images/generations`、`images/edits`） | 已实现，含多参考图编辑、URL 与 Base64 输出 |
| OpenAI Chat Completions + `generate_image` 工具 | 已实现（Agent 模式） |
| Anthropic Messages + `generate_image` 工具 | 已实现（Agent 模式） |
| OpenAI Images SSE 流式结果 | 已实现，可在图片接口兼容选项中开启 |
| OpenAI Responses 生图工具 | 未实现 |
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

桌面产物**没有签名**：Windows SmartScreen 会提示「未知发布者」，macOS 需要右键打开。消除这一点需要 Authenticode 证书和 Apple Developer ID。Windows **没有 32 位版本** —— Flutter 不提供 32 位 Windows 目标（`TargetPlatform` 只有 `windows_x64` 与 `windows_arm64`）。

## 结构

```
lib/core/    数据层 store、数据模型 models、协议适配 api、应用状态 studio
lib/ui/      shell（画廊 + Agent）、settings（设置）
lib/l10n/    六语言文案与查表
platform/    各平台自有原生文件，叠加到 flutter create 的产物上
scripts/     平台脚手架、文案生成
docs/        调研与设计
test/        协议解析、配置校验、文案一致性
```

## 文档

- [docs/image-workflow.md](docs/image-workflow.md) — 图片接口对齐、画廊与提交行为、验证边界

- [docs/agent-settings.md](docs/agent-settings.md) — 设置分栏、对话内切换模型与自定义提示词/上下文参数
- [docs/research.md](docs/research.md) — 技术选型调研与产品设计（画廊/Agent、存储、签名、CI 的完整设计）
- [docs/capabilities.md](docs/capabilities.md) — 接口能力矩阵与降级规则

## 待办

- [ ] 四平台实机验收：首次配置、多选参考图、切后台、相册保存、分享、备份恢复
- [ ] 真实 OpenAI / Claude 兼容服务联调，逐个确认支持范围
- [ ] 用真实 SDK 跑一次 `dart format` 并把格式检查加进 CI
- [ ] Windows / macOS / Linux 的代码签名证书
- [ ] Windows 安装向导的中文界面（Inno 不自带简体中文 .isl）
- [ ] AUR 提交（目前只提供 `.pkg.tar.zst` 与源码包）

## 许可证

**GPL-3.0-or-later**，全文见 [LICENSE](LICENSE)。选用它有一个连带义务：**分发二进制时必须提供对应源码**。本仓库公开即可满足，发布页也会附带 `-source.tar.gz`。若将来想闭源分发，必须先换许可证。

设计上参考了 Kelivo、Cherry Studio、NextChat、LobeHub 等项目的公开做法（见 [docs/research.md](docs/research.md)），没有复用它们的源码。

---

## English

**Imagyn** is a minimalist AI image studio for Android, Linux, Windows and macOS. Two entry points — **Gallery** (prompt plus zero or more reference images) and **Agent** (conversational generation and iteration) — over any OpenAI- or Anthropic-compatible endpoint you configure yourself. History and artwork stay on your device; API keys live in the system secure storage. The interface ships in the six UN official languages, including right-to-left Arabic.

Status: **work in progress.** The code is in place, but cross-platform device acceptance and live-service integration are not done yet.

Implemented: OpenAI Images (`images/generations`, `images/edits`) with multiple reference images, and the `generate_image` tool over OpenAI Chat Completions and Anthropic Messages. Not implemented: the OpenAI Responses image tool, streaming, mask editing, batch jobs, cloud sync, local inference. "OpenAI/Claude compatible" describes a wire format only — it does not guarantee image output.

Build instructions, layout and open questions are in the sections above. Documentation lives in [`docs/`](docs/).
