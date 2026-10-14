# AI 图片客户端：第一轮调研与建议

调研日期：2026-10-15。定位：Android、Linux、Windows、macOS 上的简洁图片生成客户端。以下是产品和架构建议，尚未开发、运行或比较框架性能。

## 建议方向

首选候选为 Flutter，Tauri 2 保留作性能对照。主入口确定为“画廊”和“Agent”，设置通过齿轮进入。采用本地作品库、用户自带 API Key、自定义服务地址；两种入口共用图片、版本和生成任务。

用户偏好依据：`.qwen/memories` 中关于低资源占用、模块解耦、手机触控、实测验证、少量批量请求的记录。网络记录指向手机使用 ghfast.top 获取 GitHub 内容，服务器直连；没有找到通用 HTTP/SOCKS 代理地址。GitHub 研究已通过 gh 完成。

## 项目研究

| 项目 | 已阅读的依据 | 适合借鉴的做法 |
| --- | --- | --- |
| [Kelivo](https://github.com/Chevey339/kelivo) | README、pubspec、OpenAI Images 实现、provider HTTP client | Flutter 手机与桌面路线；独立 Images 适配；按服务商配置代理 |
| [Cherry Studio](https://github.com/CherryHQ/cherry-studio) | package.json、绘图参数架构文档、PaintingComposer | 模型能力驱动参数与验证；把参数收进弹出面板；生成任务与界面分开 |
| [NextChat](https://github.com/ChatGPTNextWeb/NextChat) | package.json、src-tauri/tauri.conf.json | Web UI 加桌面壳路线；本次读取的壳配置为 Tauri 1 结构，不能用它证明 Android 原生适配 |
| [LobeHub](https://github.com/lobehub/lobehub) | 图片工具执行服务源码 | 图片生成、状态查询、作品记录分层；本产品可保留这种分层并减少服务端依赖 |
| [Flopsy](https://github.com/rafiusks/Flopsy) | README | 提示词主导的专用生图界面；它的 Python 本地推理架构不适合作为本项目第一版的必要依赖 |

源码参考：[Kelivo Images](https://github.com/Chevey339/kelivo/blob/master/lib/core/services/api/providers/openai_images.dart)、[Kelivo 网络层](https://github.com/Chevey339/kelivo/blob/master/lib/core/services/network/provider_http_client.dart)、[Cherry 参数架构](https://github.com/CherryHQ/cherry-studio/blob/main/docs/references/ai/image-generation-parameters.md)、[Cherry 输入面板](https://github.com/CherryHQ/cherry-studio/blob/main/src/renderer/pages/paintings/components/PaintingComposer.tsx)、[NextChat 壳配置](https://github.com/ChatGPTNextWeb/NextChat/blob/main/src-tauri/tauri.conf.json)、[LobeHub 图片执行服务](https://github.com/lobehub/lobehub/blob/canary/apps/server/src/services/toolExecution/serverRuntimes/imageGeneration.ts)。这些链接指向变化中的分支，后续实现前应固定参考提交。

Kelivo 与 Cherry Studio 的 GitHub 元数据显示 AGPL-3.0。本轮只研究设计；如果后续要复用源码，应先确定本项目许可证与复用方式。

## 接口兼容边界

| 接口 | 建议用途 | 兼容要求 |
| --- | --- | --- |
| OpenAI Images | 直接生成、修改图片 | 生成与编辑分别适配；处理图片 URL 与 Base64；按模型约束发送参数 |
| OpenAI Responses | 工具形式生成图片、连续修改 | 处理 image_generation 工具结果、流式事件和上下文 |
| OpenAI Chat Completions | 提示词辅助、图片分析；部分第三方扩展生图 | 官方通用接口不能作为统一生图保证；扩展输出格式单独适配 |
| Anthropic Messages | 可选的提示词优化、参考图分析 | 官方 Claude 不直接生成照片或插画；第三方图片扩展须以服务文档或响应样本为依据 |

“OpenAI/Claude 兼容”是协议格式声明，不保证图片输出、参考图、透明背景、分辨率或任务恢复能力。能力来自预设配置、服务文档、用户手动覆盖和实际调用反馈。模型列表本身不足以可靠判断这些能力。

来源：[OpenAI 图片能力概览](https://developers.openai.com/api/docs/guides/images-vision)、[Responses 生图工具](https://developers.openai.com/api/docs/guides/tools-image-generation)、[Claude 官方图片说明](https://support.claude.com/en/articles/9002504-can-claude-produce-images)、[Claude 视觉输入](https://platform.claude.com/docs/en/build-with-claude/vision)。

## 技术路线

Flutter 已有 Kelivo 这样的手机与桌面同代码库案例；适合优先保证 Android 触控和一致的绘图交互。它仍需要自身渲染引擎，最低内存占用不能靠框架名称推断。[Flutter 官方平台说明](https://docs.flutter.dev/platform-integration)。

Tauri 2 使用各平台 WebView，值得作为较小安装包路线评估；Windows、Linux、Android 的运行时差异、触控、文件保存、代理插件和后台任务需要实际验证。小安装包不等于低运行内存。[Tauri 官方前置依赖](https://v2.tauri.app/start/prerequisites/)。

正式选型前，只做同功能小样：一张大图预览、100 张作品缩略图、提示词输入、一个模拟长任务。测空闲 CPU、生成等待 CPU、进程总内存、峰值内存、启动时间和安装包大小。Android 与低功耗 Linux 设备先测，Windows/macOS 的图形行为仍需对应系统验证。

构建使用对应平台的工具链；Linux 构建服务器可以承担 Linux/Android 工作，Windows 与 macOS 单独配置构建环境。Termux 用于研究、编辑与轻量检查，不把完整跨平台编译能力作为默认前提。

## 简洁界面：画廊与 Agent

主导航只有“画廊”和“Agent”。桌面窄侧栏，手机底部导航；设置放齿轮入口。画廊展示生成历史和图片预览，输入区直接接受提示词与零张或多张参考图：

> 描述你想画的内容……
>
> 添加参考图（支持多选） · 模型 · 比例 · 更多参数 · 生成

参考图以编号缩略图排列，可移除与调整顺序；提示词可以写“图 1 的人物、图 2 的衣服”。不能把多图静默拼成一张来冒充支持，也不能静默丢弃超限图片。模型不支持多图时说明限制并提供兼容模型选择。

Agent 展示对话与生成图片，支持连续提出修改要求、上传多张参考图、引用历史结果。默认修改最新结果，并在输入区显示当前目标；存在多个可能目标时让用户选择。讨论与生成分别显示状态，普通讨论不会自动启动收费生图。每次修改保存独立版本，旧图可回看；Agent 的图片也在画廊出现。

质量、张数、输出格式、透明背景等收进“更多参数”；仅显示当前模型支持的选项。提示词优化为可选按钮，用户可预览并接受改写。服务地址与密钥只在设置中配置。拖放、悬停和右键操作都提供手机可点击的替代入口，键盘弹出时仍能操作生成按钮。

画廊按需加载缩略图；点开才解码大图。网络等待、图片处理、持久化均不阻塞主界面。存储、首次引导和兼容规则详见以下交付设计。

## 国内网络与任务可靠性

- 自定义 Base URL、模型 ID、必要请求头；参数映射与响应解析由接口适配器处理。
- 统一网络层供 API、图片下载和能力请求使用；跨域图片下载不附带原 API 密钥。
- 桌面与 Android 分别核实系统代理行为；提供明确的直连、系统、手动代理选项，HTTP/SOCKS 支持以实际网络实现和平台测试为准。
- UI、字体、图标随安装包提供；作品浏览与整理可离线使用。更新提示失败不会阻塞启动。
- Flutter 官方有中国网络镜像指引，但 Android SDK、Gradle、插件和其他依赖仍须分别验证可下载性。[官方指引](https://docs.flutter.dev/community/china)。
- 区分提交失败、提交结果未知、生成中、下载失败。提交后超时不自动重发收费生成请求；优先使用服务端任务查询或幂等机制，无此能力则保留“状态未知”并说明重试可能产生新任务。
- 已获得图片地址但下载失败时只重试下载。及时保存原图，减少临时地址过期造成的作品丢失。
- Android 切后台可能暂停或终止请求。持久化任务状态；服务支持查询时可恢复查询，无法查询时不能承诺杀进程后恢复结果。

## 第一版范围与待验证项

第一版：首次引导、接口检查、画廊文字生图与多参考图、Agent 对话生图、基本参数、作品与版本、本地保存分享、备份恢复、明确的任务状态。高级蒙版编辑、批量任务、云同步与本地推理作为后续扩展。

仍需验证：实际使用的兼容服务及其响应格式；Flutter/Tauri 同场景资源测量；四个平台的代理、密钥存储、图片保存和后台行为。现阶段可确定产品交互和分层，不能宣称任意兼容服务都能生图，也不能宣称某框架性能最优。

## 首次启动与配置状态

使用本地数据库中的 onboardingVersion、schemaVersion 和服务配置状态决定显示内容，不通过设备标识或“是否安装过”猜测。

- 没有引导记录且没有已有业务数据：显示“添加服务 / 导入备份 / 先浏览”。
- 有旧数据或恢复数据：保留数据，运行版本迁移；仅补充缺失配置。
- 引导未完成：继续未完成的步骤，不把半途退出当成完成。
- 已完成引导但服务缺少密钥：允许看画廊与历史，在尝试调用时引导补密钥。
- 数据库打不开、迁移失败或安全存储不可用：显示可恢复错误，不能将其当成首次启动并覆盖旧数据。

添加服务顺序：地址与协议、密钥、连接检查、获取或手动填写模型、选择图片模型、可选 Agent 对话模型。连接检查不等同于生图测试；首次配置不自动发收费图片请求。用户明确点击能力测试后才运行并显示测试状态。

清除应用数据通常会清除记录；系统恢复可能重新带回旧数据，因此只能可靠判断“当前数据是否需要引导”，不能承诺识别设备上真正的第一次安装。参考：[Kelivo 的数据库安装与恢复设计](https://github.com/Chevey339/kelivo/blob/master/lib/core/database/database_installation_gate.dart)。

## 历史与文件存储

本地 SQLite 保存服务配置（密钥只存引用）、模型能力、会话、消息、图片附件、生成任务、参数快照、作品版本与父版本关系。每张图记录本地资产 ID、相对路径、MIME、尺寸、摘要和来源，历史不依赖短期远程 URL。

持久目录分为 database/、assets/originals/、assets/references/，可重建的缩略图和临时下载放缓存目录。原图与已提交任务的参考图不能放会被系统清理的缓存目录。文件先写临时文件并完成校验，再落成正式文件和数据库记录；启动时处理未完成写入与任务状态，避免半张图被标为成功。

导入参考图时通过系统选择器读取，再复制到私有持久库；不能假设 content URI 可以转换为真实路径。桌面数据目录通过平台 API 获取，不硬编码用户名或磁盘。分页读取历史，缩略图解码和 Base64 处理放后台，限制并发与解码尺寸。

## 无 root Android 的选择、保存与备份

私有工作库只供本应用使用；普通文件管理器不能直接打开它。用户可访问的生成图片默认另存至共享 Pictures/<应用名>/，使用 MediaStore.Images 的 ContentResolver 与相对目录操作，不直接写死 /data/data 或 /Android/data。保存成功后才显示“已存入相册”；导出失败仍保留私有原图并允许重试。自动存相册可在设置关闭。

参考图主路径使用系统 Storage Access Framework 的 ACTION_OPEN_DOCUMENT、image/*、多选；系统相册选择器可以作为增强入口，必须保留文件选择器回退。这样不要求 Google Play 服务、Google 相册、root 或整个磁盘访问权限。Android 10+ 保存应用自身新建媒体无需广泛存储权限；若后续支持更早版本，再设计对应权限分支。最低 Android 版本暂建议 API 29，并通过依赖与 APK 验证确认。

保存到下载或自选位置使用系统“另存为”入口；分享使用 content URI 与临时读权限。无 root 手机可通过相册、支持共享存储的文件管理器、分享和应用导出访问图片。私有 SQLite 历史通过应用导出的备份访问。

备份通过系统文件选择器导出版本化压缩包：元数据、消息、图片、参考图与校验清单；默认不带 API 密钥。恢复时在临时位置验证格式、路径与完整性，校验通过才写入业务库；密钥需重新填写。不能直接复制正在写入的 SQLite 主文件而遗漏 WAL。卸载会删除私有历史；公共图片仍可保留，完整历史依赖备份恢复。

参考：[Android 官方存储示例](https://github.com/android/storage-samples)、[系统文件选择器示例](https://github.com/android/storage-samples/tree/main/ActionOpenDocument)、[MediaStore 示例](https://github.com/android/storage-samples/tree/main/MediaStore)。本轮通过 gh 获取项目目录，具体插件与原生实现仍需后续逐项验证。

## Agent 与协议适配

统一内部消息和附件结构，网络适配层分别转换 OpenAI Chat Completions、Responses、Anthropic Messages 和 Images。不得直接把同一个 JSON 请求体发送给所有协议。

Agent 有两条明确实现路径：

1. 服务原生支持对话生成图片：由对应适配器解析文字、图片与生成状态；连续修改按该服务支持的上下文方式执行。
2. 对话模型与图片模型分离：Agent 负责理解需求，通过受限的 generate_image / edit_image 工具调用图片适配器。Claude 等对话服务可走此路线，图片模型可在另一个服务上。

对话模型能力分别记录：图片输入、多图输入、工具调用；图片模型另记：图片输出、多参考图、编辑、格式、尺寸、任务查询。Agent 图片理解与图片生成是两个检查项。不会看图的对话模型不能被标为支持参考图分析。

支持工具调用时由客户端执行经过校验的图片工具；不支持时可进入明确的应用编排模式，将结构化绘图指令校验后执行，若解析失败就保留文本回复并提示重新提交。能力不足时应提供明确降级，不能声称完全兼容。第一版 Agent 的工具范围限制为图片相关功能，不需要系统命令、文件修改或外部代码执行。

上下文引用本地资产 ID，发送时按协议转换。只提交当前需要的目标图与参考图，历史文字可摘要；压缩不能悄悄丢失当前图片目标、参考图顺序和创作约束。一次生成有一个任务 ID，避免重复工具事件造成重复收费。

## 模型探测与检查

分开显示“已获取模型列表”“已通过连接检查”“能力由预设提供”“能力已实测”“未知/失败”。按协议获取模型列表，不支持列表的兼容服务允许手动添加；不得因为 /models 返回失败就判定服务无法生成图片。

能力配置来源为服务预设、用户覆盖与检查结果，保留来源、时间和诊断。名称只能提供猜测，不能证明图片能力。服务地址或模型改变后旧检查结果失效；认证、限流、超时、协议错误和能力不支持分别显示。

可选检查按低成本到高成本进行：连接与模型列表、最小文字回复、单图输入、多图输入、工具调用、最小生图、多参考图编辑。需付费的生成测试由用户主动触发；不要自动扫描所有模型或逐个生成图片。多图测试要验证两张参考实际参与，而非只检查 HTTP 200。

适配器测试覆盖：URL/Base64 输出、SSE 分片、工具调用参数、纯文字未出图、错误体、超限附件、中断与重复事件、生成成功但下载失败。真实服务检查与离线协议样本测试分别报告。

## 签名与 GitHub CI 交付设计

当前尚无应用仓库、包名和实际密钥，因此这里只确定配置与验收规则，尚未配置或运行 workflow。

Android 固定 applicationId，发布版使用长期保存的 release keystore；密钥和密码不进仓库。GitHub release 环境保存 ANDROID_KEYSTORE_BASE64、ANDROID_KEYSTORE_PASSWORD、ANDROID_KEY_ALIAS、ANDROID_KEY_PASSWORD。构建时临时生成 keystore 与 key.properties，结束清理。签名缺失则发布任务失败，不回退到 debug 签名。调试包使用独立 applicationIdSuffix，避免和正式包互相覆盖。versionCode 单调递增，发布前验证 APK 的 minSdk、ABI 与签名证书摘要，并进行覆盖安装验证。

workflow 计划拆为：

| 文件 | 触发 | 工作 |
| --- | --- | --- |
| .github/workflows/check.yml | PR 与主分支 push | 格式、分析、数据库迁移与协议样本测试；不接触发布密钥 |
| .github/workflows/build.yml | 主分支或手动 | 固定 SDK/依赖，四平台构建并上传测试产物，明确其签名状态 |
| .github/workflows/release.yml | v* tag 或手动 | 受信代码构建、平台签名、包校验、哈希与 Release 资产发布 |

构建 runner：Android/Linux 使用固定 Ubuntu runner，Windows 使用固定 Windows runner，macOS 使用匹配目标架构的 macOS runner。固定 Flutter、JDK、Gradle、NDK 和关键 action 版本，提交锁文件。各 job 使用最小权限，只有发布 job 获得 contents: write；fork PR 不接触发布 secrets，不使用高权限工作流执行外部 PR 代码。

Android 先提供 arm64 APK 与通用 APK，其他 ABI 以实际测试为准；Windows 分发包含必需运行库；Linux 包包含运行依赖说明；macOS 面向普通用户分发需要规划 Developer ID 签名与公证，Windows Authenticode 证书也单独配置。没有相应证书不能宣称已完成平台签名。

国内本地构建与 GitHub hosted runner 使用分开的依赖获取配置：本地 Flutter/pub 使用已核实镜像，Maven/Gradle 可配置镜像，Android SDK 与构建工具单独验证下载来源和完整性；不能以配置 Maven 镜像替代 SDK 可下载性验证。GitHub runner 可以使用其可访问源，最终 APK 的运行不依赖 Google 服务。发布文件提供校验值；国内下载镜像作为分发补充，ghfast.top 仅为可选 GitHub 获取路径，不能成为软件运行依赖。

参考：[Kelivo 多平台构建 workflow](https://github.com/Chevey339/kelivo/blob/master/.github/workflows/build-stable.yml)。本次读取的该 workflow 固定 Flutter 版本与其当前 pubspec 的版本要求不同，因此只借鉴结构，不直接照抄版本或宽泛 permissions。

## 交付验收

必须实际验证：无 root 且无 Google Play 服务手机上首次配置、多选参考图、切后台、生成、相册保存、分享、备份恢复；同签名覆盖更新后历史仍在；恢复备份后密钥缺失可重新配置。分别验证实际 OpenAI/Claude 兼容服务和多图模型，再报告支持范围。CI 成功构建不能替代四个平台的 UI 与系统集成验收。
