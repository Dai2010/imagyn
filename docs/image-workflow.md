# 图片接口与画廊调整

参考源码：CookSleep/gpt_image_playground，提交 `1e9d5af60aadd9117a835cc2da43908b8e3370dd`。本项目独立实现 Flutter 界面和协议处理，没有拷贝参考项目的 TypeScript/React 源码。

2026-10-15 核对 `image.ccttt99.com` 的公开部署脚本，预置配置是 `https://hub.ccttt99.com/v1`、`gpt-image-2.5-flare`、Images 模式。没有读取用户浏览器存储或调用付费接口。这能说明网页的配置，不能单独证明当前密钥下所有选项都受支持。

## 请求行为

- 文生图使用 JSON `POST images/generations`；参考图编辑使用 multipart `POST images/edits`，图片字段重复发送 `image[]`。
- 明确发送 size、quality、output_format、moderation；透明背景开启时发送 `background: transparent`，张数大于一时发送 n。默认不强制 response_format，兼容设置可选 Base64 输出。
- JPEG 禁用透明背景；选项依赖服务能力。超高与最高质量仅在 gpt-image-2.5 模型或已有该参数的任务中展示。
- 默认普通 JSON；可选 Images SSE，仅单张请求开启，支持最终 completed 事件与兼容网关的最终 data 数组。中间预览不被保存为成品。多张使用单个非流式请求，不拆成并行收费请求。
- 图片等待超时为十分钟；不自动重试图片生成。下载使用独立无认证客户端；远程 URL 下载失败时保留 URL，仅重试下载。混合 Base64/URL 的部分失败尚不支持下载恢复。
- API 密钥继续只发往用户配置的地址；ghfast.top 仅供开发下载 GitHub 源码，不进入应用生图链路。

## 交互行为

画廊采用左图右文卡片，支持提示词/模型搜索、任务状态筛选、收藏、复用提示词与参数。参数集中在底部面板，保留双列布局，主输入区保持紧凑。

本地参数与连接校验通过、任务写入数据库后立即清空输入框；生成期间仍可编辑下一条草稿，生成完成不会再次清空。校验失败保留原文。Agent 在用户消息保存后清空。

生成中的任务与失败/中断任务拥有各自卡片，参数、错误和时间保留在任务详情内。复用参数仅填回输入框，不自动启动收费任务；收起记录不取消服务端任务。

## 验证边界

离线回环 HTTP 测试覆盖 JSON、multipart、多参考图、Base64、URL 下载、HTTP 拒绝与下载恢复；SSE 样本覆盖分片、UTF-8、预览、最终结果和错误。Widget 测试覆盖清空时机、新草稿保留、校验失败与窄屏布局。

真实中转站出图和 Android 安装体验仍需要实机验收；静态分析与离线测试通过不能替代实际出图。

## 本次验证结果

Flutter 3.47.7 / Dart 3.13.5：静态分析通过，53 项离线测试全部通过。手机 Linux 容器测试使用临时 SQLite system hook 配置，不进入发行配置。

真实中转请求仅一次：使用应用 StudioApi、上述部署地址与模型，1024x1024 / auto / PNG / 原生透明背景 / moderation auto，服务返回 HTTP 400、upstream_error、The image request is invalid. Check the input and try again.，约 7.8 秒。没有自动重试、没有换模型扫描；因此尚未通过真实出图验收。
